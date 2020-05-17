(*
  This is the file that handles turning Reason JSX' agnostic function call into
  a ReasonReact-specific function call. Aka, this is a macro, using OCaml's ppx
  facilities; https://whitequark.org/blog/2014/04/16/a-guide-to-extension-
  points-in-ocaml/
  You wouldn't use this file directly; it's used by BuckleScript's
  bsconfig.json. Specifically, there's a field called `react-jsx` inside the
  field `reason`, which enables this ppx through some internal call in bsb
*)

(*
  There are two different transforms that can be selected in this file (v2 and v3):
  v2:
  transform `[@JSX] div(~props1=a, ~props2=b, ~children=[foo, bar], ())` into
  `ReactDOMRe.createElement("div", ~props={"props1": 1, "props2": b}, [|foo,
  bar|])`.
  transform `[@JSX] div(~props1=a, ~props2=b, ~children=foo, ())` into
  `ReactDOMRe.createElementVariadic("div", ~props={"props1": 1, "props2": b}, foo)`.
  transform the upper-cased case
  `[@JSX] Foo.createElement(~key=a, ~ref=b, ~foo=bar, ~children=[], ())` into
  `ReasonReact.element(~key=a, ~ref=b, Foo.make(~foo=bar, [||]))`
  transform `[@JSX] [foo]` into
  `ReactDOMRe.createElement(ReasonReact.fragment, [|foo|])`
  v3:
  transform `[@JSX] div(~props1=a, ~props2=b, ~children=[foo, bar], ())` into
  `ReactDOMRe.createDOMElementVariadic("div", ReactDOMRe.domProps(~props1=1, ~props2=b), [|foo, bar|])`.
  transform the upper-cased case
  `[@JSX] Foo.createElement(~key=a, ~ref=b, ~foo=bar, ~children=[], ())` into
  `React.createElement(Foo.make, Foo.makeProps(~key=a, ~ref=b, ~foo=bar, ()))`
  transform the upper-cased case
  `[@JSX] Foo.createElement(~foo=bar, ~children=[foo, bar], ())` into
  `React.createElementVariadic(Foo.make, Foo.makeProps(~foo=bar, ~children=React.null, ()), [|foo, bar|])`
  transform `[@JSX] [foo]` into
  `ReactDOMRe.createElement(ReasonReact.fragment, [|foo|])`
*)

open Reason_toolchain_packed.Ast_406
open Ast_helper
open Ast_mapper
open Asttypes
open Parsetree
open Longident

let rec find_opt p = function
  | [] -> None
  | x :: l -> if p x then Some x else find_opt p l



let nolabel = Nolabel
let labelled str = Labelled str
let optional str = Optional str
let isOptional str = match str with
| Optional _ -> true
| _ -> false
let isLabelled str = match str with
| Labelled _ -> true
| _ -> false
let getLabel str = match str with
| Optional str | Labelled str -> str
| Nolabel -> ""
let optionIdent = Lident "option"

let argIsKeyRef = function
  | (Labelled ("key" | "ref"), _) | (Optional ("key" | "ref"), _) -> true
  | _ -> false
let constantString ~loc str = Ast_helper.Exp.constant ~loc (Pconst_string (str, None))


let safeTypeFromValue valueStr =
let valueStr = getLabel valueStr in
match String.sub valueStr 0 1 with
| "_" -> "T" ^ valueStr
| _ -> valueStr
let keyType loc = Typ.constr ~loc {loc; txt=optionIdent} [Typ.constr ~loc {loc; txt=Lident "string"} []]

type 'a children = | ListLiteral of 'a | Exact of 'a
type componentConfig = {
  propsName: string;
}

(* if children is a list, convert it to an array while mapping each element. If not, just map over it, as usual *)
let transformChildrenIfListUpper ~loc ~mapper theList =
  let rec transformChildren_ theList accum =
    (* not in the sense of converting a list to an array; convert the AST
       reprensentation of a list to the AST reprensentation of an array *)
    match theList with
    | {pexp_desc = Pexp_construct ({txt = Lident "[]"}, None)} -> begin
      match accum with
      | [singleElement] -> Exact singleElement
      | accum -> ListLiteral (List.rev accum |> Exp.array ~loc)
      end
    | {pexp_desc = Pexp_construct (
        {txt = Lident "::"},
        Some {pexp_desc = Pexp_tuple (v::acc::[])}
      )} ->
      transformChildren_ acc ((mapper.expr mapper v)::accum)
    | notAList -> Exact (mapper.expr mapper notAList)
  in
  transformChildren_ theList []

let transformChildrenIfList ~loc ~mapper theList =
  let rec transformChildren_ theList accum =
    (* not in the sense of converting a list to an array; convert the AST
       reprensentation of a list to the AST reprensentation of an array *)
    match theList with
    | {pexp_desc = Pexp_construct ({txt = Lident "[]"}, None)} ->
      List.rev accum |> Exp.array ~loc
    | {pexp_desc = Pexp_construct (
        {txt = Lident "::"},
        Some {pexp_desc = Pexp_tuple (v::acc::[])}
      )} ->
      transformChildren_ acc ((mapper.expr mapper v)::accum)
    | notAList -> mapper.expr mapper notAList
  in
  transformChildren_ theList []

let extractChildren ?(removeLastPositionUnit=false) ~loc propsAndChildren =
  let rec allButLast_ lst acc = match lst with
    | [] -> []
    | (Nolabel, {pexp_desc = Pexp_construct ({txt = Lident "()"}, None)})::[] -> acc
    | (Nolabel, _) :: _rest -> raise (Invalid_argument "JSX: found non-labelled argument before the last position")
    | arg::rest -> allButLast_ rest (arg::acc)
  in
  let allButLast lst = allButLast_ lst [] |> List.rev in
  match (List.partition (fun (label, _) -> label = labelled "children") propsAndChildren) with
  | ([], props) ->
    (* no children provided? Place a placeholder list *)
    (Exp.construct ~loc {loc; txt = Lident "[]"} None, if removeLastPositionUnit then allButLast props else props)
  | ([(_, childrenExpr)], props) ->
    (childrenExpr, if removeLastPositionUnit then allButLast props else props)
  | _ -> raise (Invalid_argument "JSX: somehow there's more than one `children` label")

let unerasableIgnore loc = ({loc; txt = "warning"}, (PStr [Str.eval (Exp.constant (Pconst_string ("-16", None)))]))
let merlinFocus = ({loc = Location.none; txt = "merlin.focus"}, (PStr []))

(* Helper method to look up the [@react.component] attribute *)
let hasAttr (loc, _) =
  loc.txt = "react.component"

(* Helper method to filter out any attribute that isn't [@react.component] *)
let otherAttrsPure (loc, _) =
  loc.txt <> "react.component"

(* Iterate over the attributes and try to find the [@react.component] attribute *)
let hasAttrOnBinding {pvb_attributes} = find_opt hasAttr pvb_attributes <> None

(* Filter the [@react.component] attribute and immutably replace them on the binding *)
let filterAttrOnBinding binding = {binding with pvb_attributes = List.filter otherAttrsPure binding.pvb_attributes}

(* Finds the name of the variable the binding is assigned to, otherwise raises Invalid_argument *)
let getFnName binding =
  match binding with
  | {pvb_pat = {
      ppat_desc = Ppat_var {txt}
    }} -> txt
  | _ -> raise (Invalid_argument "react.component calls cannot be destructured.")

let makeNewBinding binding expression newName =
  match binding with
  | {pvb_pat = {
      ppat_desc = Ppat_var ( ppat_var)
    } as pvb_pat} ->{ binding with pvb_pat = {
        pvb_pat with
        ppat_desc = Ppat_var {ppat_var with txt = newName};
      };
      pvb_expr = expression;
      pvb_attributes = [merlinFocus];
    }
  | _ -> raise (Invalid_argument "react.component calls cannot be destructured.")

(* Lookup the value of `props` otherwise raise Invalid_argument error *)
let getPropsNameValue _acc (loc, exp) =
    match (loc, exp) with
    | ({ txt = Lident "props" }, { pexp_desc = Pexp_ident {txt = Lident str} }) -> { propsName = str }
    | ({ txt }, _) -> raise (Invalid_argument ("react.component only accepts props as an option, given: " ^ Longident.last txt))

(* Lookup the `props` record or string as part of [@react.component] and store the name for use when rewriting *)
let getPropsAttr payload =
  let defaultProps = {propsName = "Props"} in
  match payload with
  | Some(PStr(
    {pstr_desc = Pstr_eval ({
      pexp_desc = Pexp_record (recordFields, None)
      }, _)}::_rest
      )) ->
      List.fold_left getPropsNameValue defaultProps recordFields
  | Some(PStr({pstr_desc = Pstr_eval ({pexp_desc = Pexp_ident {txt = Lident "props"}}, _)}::_rest)) -> {propsName = "props"}
  | Some(PStr({pstr_desc = Pstr_eval (_, _)}::_rest)) -> raise (Invalid_argument ("react.component accepts a record config with props as an options."))
  | _ -> defaultProps

(* Plucks the label, loc, and type_ from an AST node *)
let pluckLabelDefaultLocType (label, default, _, _, loc, type_) = (label, default, loc, type_)

(* Lookup the filename from the location information on the AST node and turn it into a valid module identifier *)
let filenameFromLoc (pstr_loc: Location.t) =
  let fileName = match pstr_loc.loc_start.pos_fname with
  | "" -> !Location.input_name
  | fileName -> fileName
  in
  let fileName = try
      Filename.chop_extension (Filename.basename fileName)
    with | Invalid_argument _-> fileName in
  let fileName = String.capitalize_ascii fileName in
  fileName

(* Build a string representation of a module name with segments separated by $ *)
let makeModuleName fileName nestedModules fnName =
  let fullModuleName = match (fileName, nestedModules, fnName) with
  (* TODO: is this even reachable? It seems like the fileName always exists *)
  | ("", nestedModules, "make") -> nestedModules
  | ("", nestedModules, fnName) -> List.rev (fnName :: nestedModules)
  | (fileName, nestedModules, "make") -> fileName :: (List.rev nestedModules)
  | (fileName, nestedModules, fnName) -> fileName :: (List.rev (fnName :: nestedModules))
  in
  let fullModuleName = String.concat "$" fullModuleName in
  fullModuleName

(*
  AST node builders
  These functions help us build AST nodes that are needed when transforming a [@react.component] into a
  constructor and a props external
*)

(* Build an AST node representing all named args for the `external` definition for a component's props *)
let rec recursivelyMakeNamedArgsForExternal list args =
  match list with
  | (label, default, loc, interiorType)::tl ->
    recursivelyMakeNamedArgsForExternal tl (Typ.arrow
    ~loc
    label
    (match (label, interiorType, default) with
    (* ~foo=1 *)
    | (label, None, Some _) ->
    {
      ptyp_desc = Ptyp_var (safeTypeFromValue label);
      ptyp_loc = loc;
      ptyp_attributes = [];
    }
    (* ~foo: int=1 *)
    | (_label, Some type_, Some _) ->
    type_

    (* ~foo: option(int)=? *)
    | (label, Some ({ptyp_desc = Ptyp_constr ({txt=(Lident "option")}, [type_])}), _)
    | (label, Some ({ptyp_desc = Ptyp_constr ({txt=(Ldot (Lident "*predef*", "option"))}, [type_])}), _)
    (* ~foo: int=? - note this isnt valid. but we want to get a type error *)
    | (label, Some type_, _) when isOptional label ->
    type_
    (* ~foo=? *)
    | (label, None, _) when isOptional label ->
    {
      ptyp_desc = Ptyp_var (safeTypeFromValue label);
      ptyp_loc = loc;
      ptyp_attributes = [];
    }

    (* ~foo *)
    | (label, None, _) ->
    {
      ptyp_desc = Ptyp_var (safeTypeFromValue label);
      ptyp_loc = loc;
      ptyp_attributes = [];
    }
    | (_label, Some type_, _) ->
    type_
    )
    args)
  | [] -> args

(* Build an AST node for the [@bs.obj] representing props for a component *)
let makePropsValue fnName loc namedArgListWithKeyAndRef propsType =
  let propsName = fnName ^ "Props" in {
  pval_name = {txt = propsName; loc};
  pval_type =
      recursivelyMakeNamedArgsForExternal
        namedArgListWithKeyAndRef
        (Typ.arrow
          nolabel
          {
            ptyp_desc = Ptyp_constr ({txt= Lident("unit"); loc}, []);
            ptyp_loc = loc;
            ptyp_attributes = [];
          }
          propsType
        );
  pval_prim = [""];
  pval_attributes = [({txt = "bs.obj"; loc = loc}, PStr [])];
  pval_loc = loc;
}

(* Build an AST node representing an `external` with the definition of the [@bs.obj] *)
let makePropsExternal fnName loc namedArgListWithKeyAndRef propsType =
  {
    pstr_loc = loc;
    pstr_desc = Pstr_primitive (makePropsValue fnName loc namedArgListWithKeyAndRef propsType)
  }

(* Build an AST node for the signature of the `external` definition *)
let makePropsExternalSig fnName loc namedArgListWithKeyAndRef propsType =
  {
    psig_loc = loc;
    psig_desc = Psig_value (makePropsValue fnName loc namedArgListWithKeyAndRef propsType)
  }

(* Build an AST node for the props name when converted to a Js.t inside the function signature  *)
let makePropsName ~loc name =
  {
    ppat_desc = Ppat_var {txt = name; loc};
    ppat_loc = loc;
    ppat_attributes = [];
  }


let makeObjectField loc (str, attrs, type_) =
  Otag ({ loc; txt = str }, attrs, type_)


(* Build an AST node representing a "closed" Js.t object representing a component's props *)
let makePropsType ~loc namedTypeList =
  Typ.mk ~loc (
    Ptyp_constr({txt= Ldot (Lident("Js"), "t"); loc}, [{
        ptyp_desc = Ptyp_object(
          List.map (makeObjectField loc) namedTypeList,
          Closed
        );
        ptyp_loc = loc;
        ptyp_attributes = [];
      }])
    )

(* Builds an AST node for the entire `external` definition of props *)
let makeExternalDecl fnName loc namedArgListWithKeyAndRef namedTypeList =
  makePropsExternal
    fnName
    loc
    (List.map pluckLabelDefaultLocType namedArgListWithKeyAndRef)
    (makePropsType ~loc namedTypeList)

(* TODO: some line number might still be wrong *)
let jsxMapper () =

  let jsxVersion = ref None in

  let transformUppercaseCall3 modulePath mapper loc attrs _ callArguments =
    let (children, argsWithLabels) = extractChildren ~loc ~removeLastPositionUnit:true callArguments in
    let argsForMake = argsWithLabels in
    let childrenExpr = transformChildrenIfListUpper ~loc ~mapper children in
    let recursivelyTransformedArgsForMake = argsForMake |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression)) in
    let childrenArg = ref None in
    let args = recursivelyTransformedArgsForMake
      @ (match childrenExpr with
        | Exact children -> [(labelled "children", children)]
        | ListLiteral ({ pexp_desc = Pexp_array list }) when list = [] -> []
        | ListLiteral expression ->
        (* this is a hack to support react components that introspect into their children *)
        (childrenArg := Some expression;
        [(labelled "children", Exp.ident ~loc {loc; txt = Ldot (Lident "React", "null")})]))
      @ [(nolabel, Exp.construct ~loc {loc; txt = Lident "()"} None)] in
    let isCap str = let first = String.sub str 0 1 in
    let capped = String.uppercase_ascii first in first = capped in
    let ident = match modulePath with
    | Lident _ -> Ldot (modulePath, "make")
    | (Ldot (_modulePath, value) as fullPath) when isCap value -> Ldot (fullPath, "make")
    | modulePath -> modulePath in
    let propsIdent = match ident with
    | Lident path -> Lident (path ^ "Props")
    | Ldot(ident, path) -> Ldot (ident, path ^ "Props")
    | _ -> raise (Invalid_argument "JSX name can't be the result of function applications") in
    let props =
    Exp.apply ~attrs ~loc (Exp.ident ~loc {loc; txt = propsIdent}) args in
    (* handle key, ref, children *)
      (* React.createElement(Component.make, props, ...children) *)
    match (!childrenArg) with
    | None ->
      (Exp.apply
        ~loc
        ~attrs
        (Exp.ident ~loc {loc; txt = Ldot (Lident "React", "createElement")})
        ([
          (nolabel, Exp.ident ~loc {txt = ident; loc});
          (nolabel, props)
        ]))
     | Some children ->
       (Exp.apply
         ~loc
         ~attrs
         (Exp.ident ~loc {loc; txt = Ldot (Lident "React", "createElementVariadic")})
         ([
           (nolabel, Exp.ident ~loc {txt = ident; loc});
           (nolabel, props);
           (nolabel, children)
         ]))
     in

    let transformLowercaseCall3 mapper loc attrs callArguments id =
      let (children, nonChildrenProps) = extractChildren ~loc callArguments in
      let componentNameExpr = constantString ~loc id in
      let childrenExpr = transformChildrenIfList ~loc ~mapper children in
      let createElementCall = match children with
        (* [@JSX] div(~children=[a]), coming from <div> a </div> *)
        | {
            pexp_desc =
             Pexp_construct ({txt = Lident "::"}, Some {pexp_desc = Pexp_tuple _ })
             | Pexp_construct ({txt = Lident "[]"}, None)
          } -> "createDOMElementVariadic"
        (* [@JSX] div(~children= value), coming from <div> ...(value) </div> *)
        | _ -> raise (Invalid_argument "A spread as a DOM element's \
          children don't make sense written together. You can simply remove the spread.")
      in
      let args = match nonChildrenProps with
        | [_justTheUnitArgumentAtEnd] ->
          [
            (* "div" *)
            (nolabel, componentNameExpr);
            (* [|moreCreateElementCallsHere|] *)
            (nolabel, childrenExpr)
          ]
        | nonEmptyProps ->
          let propsCall =
            Exp.apply
              ~loc
              (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", "domProps")})
              (nonEmptyProps |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression)))
          in
          [
            (* "div" *)
            (nolabel, componentNameExpr);
            (* ReactDOMRe.props(~className=blabla, ~foo=bar, ()) *)
            (labelled "props", propsCall);
            (* [|moreCreateElementCallsHere|] *)
            (nolabel, childrenExpr)
          ] in
      Exp.apply
        ~loc
        (* throw away the [@JSX] attribute and keep the others, if any *)
        ~attrs
        (* ReactDOMRe.createElement *)
        (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", createElementCall)})
        args
    in

  let transformUppercaseCall modulePath mapper loc attrs _ callArguments =
    let (children, argsWithLabels) = extractChildren ~loc ~removeLastPositionUnit:true callArguments in
    let (argsKeyRef, argsForMake) = List.partition argIsKeyRef argsWithLabels in
    let childrenExpr = transformChildrenIfList ~loc ~mapper children in
    let recursivelyTransformedArgsForMake = argsForMake |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression)) in
    let args = recursivelyTransformedArgsForMake @ [ (nolabel, childrenExpr) ] in
    let wrapWithReasonReactElement e = (* ReasonReact.element(~key, ~ref, ...) *)
      Exp.apply
        ~loc
        (Exp.ident ~loc {loc; txt = Ldot (Lident "ReasonReact", "element")})
        (argsKeyRef @ [(nolabel, e)]) in
    Exp.apply
      ~loc
      ~attrs
      (* Foo.make *)
      (Exp.ident ~loc {loc; txt = Ldot (modulePath, "make")})
      args
    |> wrapWithReasonReactElement in

  let transformLowercaseCall mapper loc attrs callArguments id =
    let (children, nonChildrenProps) = extractChildren ~loc callArguments in
    let componentNameExpr = constantString ~loc id in
    let childrenExpr = transformChildrenIfList ~loc ~mapper children in
    let createElementCall = match children with
      (* [@JSX] div(~children=[a]), coming from <div> a </div> *)
      | {
          pexp_desc =
           Pexp_construct ({txt = Lident "::"}, Some {pexp_desc = Pexp_tuple _ })
           | Pexp_construct ({txt = Lident "[]"}, None)
        } -> "createElement"
      (* [@JSX] div(~children=[|a|]), coming from <div> ...[|a|] </div> *)
      | { pexp_desc = (Pexp_array _) } ->
        raise (Invalid_argument "A spread + an array literal as a DOM element's \
          children would cancel each other out, and thus don't make sense written \
          together. You can simply remove the spread and the array literal.")
      (* [@JSX] div(~children= <div />), coming from <div> ...<div/> </div> *)
      | {
          pexp_attributes
        } when pexp_attributes |> List.exists (fun (attribute, _) -> attribute.txt = "JSX") ->
        raise (Invalid_argument "A spread + a JSX literal as a DOM element's \
          children don't make sense written together. You can simply remove the spread.")
      | _ -> "createElementVariadic"
    in
    let args = match nonChildrenProps with
      | [_justTheUnitArgumentAtEnd] ->
        [
          (* "div" *)
          (nolabel, componentNameExpr);
          (* [|moreCreateElementCallsHere|] *)
          (nolabel, childrenExpr)
        ]
      | nonEmptyProps ->
        let propsCall =
          Exp.apply
            ~loc
            (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", "props")})
            (nonEmptyProps |> List.map (fun (label, expression) -> (label, mapper.expr mapper expression)))
        in
        [
          (* "div" *)
          (nolabel, componentNameExpr);
          (* ReactDOMRe.props(~className=blabla, ~foo=bar, ()) *)
          (labelled "props", propsCall);
          (* [|moreCreateElementCallsHere|] *)
          (nolabel, childrenExpr)
        ] in
    Exp.apply
      ~loc
      (* throw away the [@JSX] attribute and keep the others, if any *)
      ~attrs
      (* ReactDOMRe.createElement *)
      (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", createElementCall)})
      args
  in

  let rec recursivelyTransformNamedArgsForMake mapper expr list =
    let expr = mapper.expr mapper expr in
    match expr.pexp_desc with
    (* TODO: make this show up with a loc. *)
    | Pexp_fun (Labelled "key", _, _, _)
    | Pexp_fun (Optional "key", _, _, _) -> raise (Invalid_argument "Key cannot be accessed inside of a component. Don't worry - you can always key a component from its parent!")
    | Pexp_fun (Labelled "ref", _, _, _)
    | Pexp_fun (Optional "ref", _, _, _) -> raise (Invalid_argument "Ref cannot be passed as a normal prop. Please use `forwardRef` API instead.")
    | Pexp_fun (arg, default, pattern, expression) when isOptional arg || isLabelled arg ->
      let () =
      (match (isOptional arg, pattern, default) with
      | (true, { ppat_desc = Ppat_constraint (_, { ptyp_desc })}, None) ->
        (match ptyp_desc with
         | Ptyp_constr({txt=(Lident "option")}, [_]) -> ()
         | _ ->
             let currentType = (match ptyp_desc with
             | Ptyp_constr({txt}, []) -> String.concat "." (Longident.flatten txt)
             | Ptyp_constr({txt}, _innerTypeArgs) -> String.concat "." (Longident.flatten txt) ^ "(...)"
             | _ -> "...")
             in
             Location.prerr_warning pattern.ppat_loc
               (Preprocessor
                  (Printf.sprintf "ReasonReact: optional argument annotations must have explicit `option`. Did you mean `option(%s)=?`?" currentType)))
      | _ -> ()) in
      let alias = (match pattern with
      | {ppat_desc = Ppat_alias (_, {txt}) | Ppat_var {txt}} -> txt
      | {ppat_desc = Ppat_any} -> "_"
      | _ -> getLabel arg) in
      let type_ = (match pattern with
      | {ppat_desc = Ppat_constraint (_, type_)} -> Some type_
      | _ -> None) in

      recursivelyTransformNamedArgsForMake mapper expression ((arg, default, pattern, alias, pattern.ppat_loc, type_) :: list)
    | Pexp_fun (Nolabel, _, { ppat_desc = (Ppat_construct ({txt = Lident "()"}, _) | Ppat_any)}, _expression) ->
        (list, None)
    | Pexp_fun (Nolabel, _, { ppat_desc = Ppat_var ({txt})}, _expression) ->
        (list, Some txt)

    | _ -> (list, None)
  in


  let argToType types (name, default, _noLabelName, _alias, loc, type_) = match (type_, name, default) with
    | (Some ({ptyp_desc = Ptyp_constr ({txt=(Lident "option")}, [type_])}), name, _) when isOptional name ->
      (getLabel name, [], {
        type_ with
        ptyp_desc = Ptyp_constr ({loc=type_.ptyp_loc; txt=optionIdent}, [type_]);
      }) :: types
    | (Some type_, name, Some _default) ->
      (getLabel name, [], {
      ptyp_desc = Ptyp_constr ({loc; txt=optionIdent}, [type_]);
      ptyp_loc = loc;
      ptyp_attributes = [];
      }) :: types
    | (Some type_, name, _) ->
      (getLabel name, [], type_) :: types
    | (None, name, _) when isOptional name ->
      (getLabel name, [], {
        ptyp_desc = Ptyp_constr ({loc; txt=optionIdent}, [{
          ptyp_desc = Ptyp_var (safeTypeFromValue name);
          ptyp_loc = loc;
          ptyp_attributes = [];
        }]);
        ptyp_loc = loc;
        ptyp_attributes = [];
        }) :: types
    | (None, name, _) when isLabelled name ->
      (getLabel name, [], {
        ptyp_desc = Ptyp_var (safeTypeFromValue name);
        ptyp_loc = loc;
        ptyp_attributes = [];
        }) :: types
    | _ -> types
  in

  let argToConcreteType types (name, loc, type_) = match name with
    | name when isLabelled name ->
    (getLabel name, [], type_) :: types
    | name when isOptional name ->
  (getLabel name, [], Typ.constr ~loc {loc; txt=optionIdent} [type_]) :: types
    | _ -> types
  in

  let nestedModules = ref([]) in
  let transformComponentDefinition mapper structure returnStructures = match structure with
  (* external *)
  | ({
      pstr_loc;
      pstr_desc = Pstr_primitive ({
        pval_name = { txt = fnName };
        pval_attributes;
        pval_type;
      } as value_description)
    } as pstr) ->
    (match List.filter hasAttr pval_attributes with
    | [] -> structure :: returnStructures
    | [_] ->
    let rec getPropTypes types ({ptyp_loc; ptyp_desc} as fullType) =
      (match ptyp_desc with
      | Ptyp_arrow (name, type_, ({ptyp_desc = Ptyp_arrow _} as rest)) when isLabelled name || isOptional name ->
        getPropTypes ((name, ptyp_loc, type_)::types) rest
      | Ptyp_arrow (Nolabel, _type, rest) ->
        getPropTypes types rest
      | Ptyp_arrow (name, type_, returnValue) when isLabelled name || isOptional name ->
        (returnValue, (name, returnValue.ptyp_loc, type_)::types)
      | _ -> (fullType, types))
    in
    let (innerType, propTypes) = getPropTypes [] pval_type in
    let namedTypeList = List.fold_left argToConcreteType [] propTypes in
    let pluckLabelAndLoc (label, loc, type_) = (label, None (* default *), loc, Some type_) in
    let retPropsType = makePropsType ~loc:pstr_loc namedTypeList in
    let externalPropsDecl = makePropsExternal fnName pstr_loc ((
      optional "key",
      None,
      pstr_loc,
      Some(keyType pstr_loc)
    ) :: List.map pluckLabelAndLoc propTypes) retPropsType in
    (* can't be an arrow because it will defensively uncurry *)
    let newExternalType = Ptyp_constr (
      {loc = pstr_loc; txt = Ldot ((Lident "React"), "componentLike")},
      [retPropsType; innerType]
    ) in
    let newStructure = {
      pstr with pstr_desc = Pstr_primitive {
        value_description with pval_type = {
          pval_type with ptyp_desc = newExternalType;
        };
        pval_attributes = List.filter otherAttrsPure pval_attributes;
      }
    } in
    externalPropsDecl :: newStructure :: returnStructures
    | _ -> raise (Invalid_argument "Only one react.component call can exist on a component at one time"))
  (* let component = ... *)
  | {
      pstr_loc;
      pstr_desc = Pstr_value (
        recFlag,
        valueBindings
      )
    } ->
      let fileName = filenameFromLoc pstr_loc in
      let emptyLoc = Location.in_file fileName in
      let mapBinding binding = if (hasAttrOnBinding binding) then
        let bindingLoc = binding.pvb_loc in
        let bindingPatLoc = binding.pvb_pat.ppat_loc in
        let binding = { binding with pvb_pat = { binding.pvb_pat with ppat_loc = emptyLoc}; pvb_loc = emptyLoc} in
        let fnName = getFnName binding in
        let internalFnName = fnName ^ "$Internal" in
        let fullModuleName = makeModuleName fileName !nestedModules fnName in
        let modifiedBindingOld binding =
          let expression = binding.pvb_expr in
          (* TODO: there is a long-tail of unsupported features inside of blocks - Pexp_letmodule , Pexp_letexception , Pexp_ifthenelse *)
          let rec spelunkForFunExpression expression = (match expression with
          (* let make = (~prop) => ... *)
          | {
            pexp_desc = Pexp_fun _
          } -> expression
          (* let make = {let foo = bar in (~prop) => ...} *)
          | {
              pexp_desc = Pexp_let (_recursive, _vbs, returnExpression)
            } ->
            (* here's where we spelunk! *)
            spelunkForFunExpression returnExpression
          (* let make = React.forwardRef((~prop) => ...) *)

          | { pexp_desc = Pexp_apply (_wrapperExpression, [(Nolabel, innerFunctionExpression)]) } ->
            spelunkForFunExpression innerFunctionExpression
          | {
              pexp_desc = Pexp_sequence (_wrapperExpression, innerFunctionExpression)
            } ->
            spelunkForFunExpression innerFunctionExpression
          | _ -> raise (Invalid_argument "react.component calls can only be on function definitions or component wrappers (forwardRef, memo).")
          ) in
          spelunkForFunExpression expression
        in
        let modifiedBinding binding =
          let wrapExpressionWithBinding expressionFn expression =
            Vb.mk
              ~loc:bindingLoc
              ~attrs:(List.filter otherAttrsPure binding.pvb_attributes)
              (Pat.var ~loc:bindingPatLoc {loc = bindingPatLoc; txt = fnName}) (expressionFn expression) in
          let expression = binding.pvb_expr in
          let unerasableIgnoreExp exp = { exp with pexp_attributes = (unerasableIgnore emptyLoc) :: exp.pexp_attributes } in
          (* TODO: there is a long-tail of unsupported features inside of blocks - Pexp_letmodule , Pexp_letexception , Pexp_ifthenelse *)
          let rec spelunkForFunExpression expression = (match expression with
          (* let make = (~prop) => ... with no final unit *)
          | {
            pexp_desc = Pexp_fun ((Labelled(_) | Optional(_) as label), default, pattern, ({pexp_desc = Pexp_fun _} as internalExpression))
          } ->
            let (wrap, hasUnit, exp) = spelunkForFunExpression internalExpression in
            (wrap, hasUnit, unerasableIgnoreExp {expression with pexp_desc = Pexp_fun (label, default, pattern, exp)})
          (* let make = (()) => ... *)
          (* let make = (_) => ... *)
          | {
            pexp_desc = Pexp_fun (Nolabel, _default, { ppat_desc = Ppat_construct ({txt = Lident "()"}, _) | Ppat_any}, _internalExpression)
            } -> ((fun a -> a), true, expression)
          (* let make = (~prop) => ... *)
          | {
            pexp_desc = Pexp_fun ((Labelled(_) | Optional(_)), _default, _pattern, _internalExpression)
          } -> ((fun a -> a), false, unerasableIgnoreExp  expression)
          (* let make = (prop) => ... *)
          | {
            pexp_desc = Pexp_fun (_nolabel, _default, _pattern, _internalExpression);
            pexp_loc
          } -> 
            Location.raise_errorf ~loc:pexp_loc 
               "Make sure to use labeled arguments for props, if your component doesn't take any props use () or _ instead of a name as your argument"
          (* let make = {let foo = bar in (~prop) => ...} *)
          | {
              pexp_desc = Pexp_let (recursive, vbs, internalExpression)
            } ->
            (* here's where we spelunk! *)
            let (wrap, hasUnit, exp) = spelunkForFunExpression internalExpression in
            (wrap, hasUnit, {expression with pexp_desc = Pexp_let (recursive, vbs, exp)})
          (* let make = React.forwardRef((~prop) => ...) *)
          | { pexp_desc = Pexp_apply (wrapperExpression, [(Nolabel, internalExpression)]) } ->
            let (_, hasUnit, exp) = spelunkForFunExpression internalExpression in
            ((fun exp -> Exp.apply wrapperExpression [(nolabel, exp)]), hasUnit, exp)
          | {
              pexp_desc = Pexp_sequence (wrapperExpression, internalExpression)
            } ->
            let (wrap, hasUnit, exp) = spelunkForFunExpression internalExpression in
            (wrap, hasUnit, {expression with pexp_desc = Pexp_sequence (wrapperExpression, exp)})
          | e -> ((fun a -> a), false, e)
          ) in
          let (wrapExpression, hasUnit, expression) = spelunkForFunExpression expression in
          (wrapExpressionWithBinding wrapExpression, hasUnit, expression)
        in
        let (bindingWrapper, hasUnit, expression) = modifiedBinding binding in
        let reactComponentAttribute = try
          Some(List.find hasAttr binding.pvb_attributes)
        with | Not_found -> None in
        let (_attr_loc, payload) = match reactComponentAttribute with
        | Some (loc, payload) -> (loc.loc, Some payload)
        | None -> (emptyLoc, None) in
        let props = getPropsAttr payload in
        (* do stuff here! *)
        let (namedArgList, forwardRef) = recursivelyTransformNamedArgsForMake mapper (modifiedBindingOld binding) [] in
        let namedArgListWithKeyAndRef = (optional("key"), None, Pat.var {txt = "key"; loc = emptyLoc}, "key", emptyLoc, Some(keyType emptyLoc)) :: namedArgList in
        let namedArgListWithKeyAndRef = match forwardRef with
        | Some(_) ->  (optional("ref"), None, Pat.var {txt = "key"; loc = emptyLoc}, "ref", emptyLoc, None) :: namedArgListWithKeyAndRef
        | None -> namedArgListWithKeyAndRef
        in
        let namedArgListWithKeyAndRefForNew = match forwardRef with
        | Some(txt) -> namedArgList @ [(nolabel, None, Pat.var {txt; loc = emptyLoc}, txt, emptyLoc, None)]
        | None -> namedArgList
        in
        let pluckArg (label, _, _, alias, loc, _) =
          let labelString = (match label with | label when isOptional label || isLabelled label -> getLabel label | _ -> "") in
          (label,
            (match labelString with
              | "" ->  (Exp.ident ~loc {
                txt = (Lident alias);
                loc
              })
              | labelString -> (Exp.apply ~loc
                (Exp.ident ~loc {txt = (Lident "##"); loc })
                [
                  (nolabel, Exp.ident ~loc {txt = (Lident props.propsName); loc });
                  (nolabel, Exp.ident ~loc {
                    txt = (Lident labelString);
                    loc
                  })
                ]
              )
            )
          ) in
        let namedTypeList = List.fold_left argToType [] namedArgList in
        let loc = emptyLoc in
        let externalDecl = makeExternalDecl fnName loc namedArgListWithKeyAndRef namedTypeList in
        let innerExpressionArgs = (List.map pluckArg namedArgListWithKeyAndRefForNew) @
          if hasUnit then [(Nolabel, Exp.construct {loc; txt = Lident "()"} None)] else [] in
        let innerExpression = Exp.apply (Exp.ident {loc; txt = Lident(
          match recFlag with
          | Recursive -> internalFnName
          | Nonrecursive -> fnName
        )}) innerExpressionArgs in
        let innerExpressionWithRef = match (forwardRef) with
        | Some txt ->
          {innerExpression with pexp_desc = Pexp_fun (nolabel, None, {
            ppat_desc = Ppat_var { txt; loc = emptyLoc };
            ppat_loc = emptyLoc;
            ppat_attributes = [];
          }, innerExpression)}
        | None -> innerExpression
        in
        let fullExpression = Exp.fun_
          nolabel
          None
          {
            ppat_desc = Ppat_constraint (
              makePropsName ~loc:emptyLoc props.propsName,
              makePropsType ~loc:emptyLoc namedTypeList
            );
            ppat_loc = emptyLoc;
            ppat_attributes = [];
          }
          innerExpressionWithRef in
        let fullExpression = match (fullModuleName) with
        | ("") -> fullExpression
        | (txt) -> Exp.let_
            Nonrecursive
            [Vb.mk
              ~loc:emptyLoc
              (Pat.var ~loc:emptyLoc {loc = emptyLoc; txt})
              fullExpression
            ]
            (Exp.ident ~loc:emptyLoc {loc = emptyLoc; txt = Lident txt}) in
        let (bindings, newBinding) =
          match recFlag with
          | Recursive -> ([bindingWrapper (Exp.let_
            ~loc:(emptyLoc)
            Recursive
            [
              makeNewBinding binding expression internalFnName;
              Vb.mk (Pat.var {loc = emptyLoc; txt = fnName}) fullExpression
            ]
            (Exp.ident {loc = emptyLoc; txt = Lident fnName}))], None)
          | Nonrecursive -> ([{ binding with pvb_expr = expression; pvb_attributes = [] }], Some(bindingWrapper fullExpression))
         in
        (Some externalDecl, bindings, newBinding)
      else
        (None, [binding], None)
      in
      let structuresAndBinding = List.map mapBinding valueBindings in
      let otherStructures (extern, binding, newBinding) (externs, bindings, newBindings) =
        let externs = match extern with
        | Some extern -> extern :: externs
        | None -> externs in
        let newBindings = match newBinding with
        | Some newBinding -> newBinding :: newBindings
        | None -> newBindings in
        (externs, binding @ bindings, newBindings)
      in
      let (externs, bindings, newBindings) = List.fold_right otherStructures structuresAndBinding ([], [], []) in
      externs @ [{
        pstr_loc;
        pstr_desc = Pstr_value (
          recFlag,
          bindings
        )
      }] @ (match newBindings with
        | [] -> []
        | newBindings -> [{
          pstr_loc = emptyLoc;
          pstr_desc = Pstr_value (
            recFlag,
            newBindings
          )
        }]) @ returnStructures
    | structure -> structure :: returnStructures in

  let reactComponentTransform mapper structures =
  List.fold_right (transformComponentDefinition mapper) structures [] in

  let transformComponentSignature _mapper signature returnSignatures = match signature with
  | ({
      psig_loc;
      psig_desc = Psig_value ({
        pval_name = { txt = fnName };
        pval_attributes;
        pval_type;
      } as psig_desc)
    } as psig) ->
    (match List.filter hasAttr pval_attributes with
    | [] -> signature :: returnSignatures
    | [_] ->
    let rec getPropTypes types ({ptyp_loc; ptyp_desc} as fullType) =
      (match ptyp_desc with
      | Ptyp_arrow (name, type_, ({ptyp_desc = Ptyp_arrow _} as rest)) when isOptional name || isLabelled name ->
        getPropTypes ((name, ptyp_loc, type_)::types) rest
      | Ptyp_arrow (Nolabel, _type, rest) ->
        getPropTypes types rest
      | Ptyp_arrow (name, type_, returnValue) when isOptional name || isLabelled name ->
        (returnValue, (name, returnValue.ptyp_loc, type_)::types)
      | _ -> (fullType, types))
    in
    let (innerType, propTypes) = getPropTypes [] pval_type in
    let namedTypeList = List.fold_left argToConcreteType [] propTypes in
    let pluckLabelAndLoc (label, loc, type_) = (label, None, loc, Some type_) in
    let retPropsType = makePropsType ~loc:psig_loc namedTypeList in
    let externalPropsDecl = makePropsExternalSig fnName psig_loc ((
      optional "key",
      None,
      psig_loc,
      Some(keyType psig_loc)
    ) :: List.map pluckLabelAndLoc propTypes) retPropsType in
        (* can't be an arrow because it will defensively uncurry *)
    let newExternalType = Ptyp_constr (
      {loc = psig_loc; txt = Ldot ((Lident "React"), "componentLike")},
      [retPropsType; innerType]
    ) in
    let newStructure = {
      psig with psig_desc = Psig_value {
        psig_desc with pval_type = {
          pval_type with ptyp_desc = newExternalType;
        };
        pval_attributes = List.filter otherAttrsPure pval_attributes;
      }
    } in
    externalPropsDecl :: newStructure :: returnSignatures
    | _ -> raise (Invalid_argument "Only one react.component call can exist on a component at one time"))
  | signature -> signature :: returnSignatures in

  let reactComponentSignatureTransform mapper signatures =
  List.fold_right (transformComponentSignature mapper) signatures [] in


  let transformJsxCall mapper callExpression callArguments attrs =
    (match callExpression.pexp_desc with
     | Pexp_ident caller ->
       (match caller with
        | {txt = Lident "createElement"} ->
          raise (Invalid_argument "JSX: `createElement` should be preceeded by a module name.")

        (* Foo.createElement(~prop1=foo, ~prop2=bar, ~children=[], ()) *)
        | {loc; txt = Ldot (modulePath, ("createElement" | "make"))} ->
          (match !jsxVersion with
          | Some 2 -> transformUppercaseCall modulePath mapper loc attrs callExpression callArguments
          | None
          | Some 3 -> transformUppercaseCall3 modulePath mapper loc attrs callExpression callArguments
          | Some _ -> raise (Invalid_argument "JSX: the JSX version must be 2 or 3"))

        (* div(~prop1=foo, ~prop2=bar, ~children=[bla], ()) *)
        (* turn that into
          ReactDOMRe.createElement(~props=ReactDOMRe.props(~props1=foo, ~props2=bar, ()), [|bla|]) *)
        | {loc; txt = Lident id} ->
          (match !jsxVersion with
          | Some 2 -> transformLowercaseCall mapper loc attrs callArguments id
          | None
          | Some 3 -> transformLowercaseCall3 mapper loc attrs callArguments id
          | Some _ -> raise (Invalid_argument "JSX: the JSX version must be 2 or 3"))

        | {txt = Ldot (_, anythingNotCreateElementOrMake)} ->
          raise (
            Invalid_argument
              ("JSX: the JSX attribute should be attached to a `YourModuleName.createElement` or `YourModuleName.make` call. We saw `"
               ^ anythingNotCreateElementOrMake
               ^ "` instead"
              )
          )

        | {txt = Lapply _} ->
          (* don't think there's ever a case where this is reached *)
          raise (
            Invalid_argument "JSX: encountered a weird case while processing the code. Please report this!"
          )
       )
     | _ ->
       raise (
         Invalid_argument "JSX: `createElement` should be preceeded by a simple, direct module name."
       )
    ) in

  let signature =
    (fun mapper signature -> default_mapper.signature mapper @@ reactComponentSignatureTransform mapper signature) in

  let structure =
    (fun mapper structure -> match structure with
      | structures -> begin
        default_mapper.structure mapper @@ reactComponentTransform mapper structures
      end
    ) in

  let expr =
    (fun mapper expression -> match expression with
       (* Does the function application have the @JSX attribute? *)
       | {
           pexp_desc = Pexp_apply (callExpression, callArguments);
           pexp_attributes
         } ->
         let (jsxAttribute, nonJSXAttributes) = List.partition (fun (attribute, _) -> attribute.txt = "JSX") pexp_attributes in
         (match (jsxAttribute, nonJSXAttributes) with
         (* no JSX attribute *)
         | ([], _) -> default_mapper.expr mapper expression
         | (_, nonJSXAttributes) -> transformJsxCall mapper callExpression callArguments nonJSXAttributes)

       (* is it a list with jsx attribute? Reason <>foo</> desugars to [@JSX][foo]*)
       | {
           pexp_desc =
            Pexp_construct ({txt = Lident "::"; loc}, Some {pexp_desc = Pexp_tuple _})
            | Pexp_construct ({txt = Lident "[]"; loc}, None);
           pexp_attributes
         } as listItems ->
          let (jsxAttribute, nonJSXAttributes) = List.partition (fun (attribute, _) -> attribute.txt = "JSX") pexp_attributes in
          (match (jsxAttribute, nonJSXAttributes) with
          (* no JSX attribute *)
          | ([], _) -> default_mapper.expr mapper expression
          | (_, nonJSXAttributes) ->
            let fragment = Exp.ident ~loc {loc; txt = Ldot (Lident "ReasonReact", "fragment")} in
            let childrenExpr = transformChildrenIfList ~loc ~mapper listItems in
            let args = [
              (* "div" *)
              (nolabel, fragment);
              (* [|moreCreateElementCallsHere|] *)
              (nolabel, childrenExpr)
            ] in
            Exp.apply
              ~loc
              (* throw away the [@JSX] attribute and keep the others, if any *)
              ~attrs:nonJSXAttributes
              (* ReactDOMRe.createElement *)
              (Exp.ident ~loc {loc; txt = Ldot (Lident "ReactDOMRe", "createElement")})
              args
         )
       (* Delegate to the default mapper, a deep identity traversal *)
       | e -> default_mapper.expr mapper e) in

  let module_binding =
    (fun mapper module_binding ->
      let _ = nestedModules := module_binding.pmb_name.txt :: !nestedModules in
      let mapped = default_mapper.module_binding mapper module_binding in
      let _ = nestedModules := List.tl !nestedModules in
      mapped
    ) in

  { default_mapper with structure; expr; signature; module_binding; }

let rewrite_implementation (code: Parsetree.structure) : Parsetree.structure =
  let mapper = jsxMapper () in
  mapper.structure mapper code
let rewrite_signature (code : Parsetree.signature) : Parsetree.signature =
  let mapper = jsxMapper () in
  mapper.signature mapper code

