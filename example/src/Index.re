/*
   Example 1: Parsing some Reason code
 */
let reasonCode = "let t = Belt.Option.map(None, a => a * 2)";
let astAndComments =
  Lexing.from_string(reasonCode) |> Refmt_api.RE.implementation_with_comments;

Js.log("--- Example 1: Parsing some Reason code ---");
Js.log("AST for: " ++ reasonCode);
Js.log(astAndComments);

/*
   Example 2: "Drilling" to get some information about the AST
 */
let structure = astAndComments->fst;
let firstItem = structure->Belt.List.head;

let () = {
  Js.log("--- Example 2: \"Drilling\" to get some information about the AST ---");
  switch (firstItem) {
  | Some({pstr_desc, pstr_loc: _}) =>
    switch (pstr_desc) {
    | Pstr_eval(_) => Js.log("Pstr_eval")
    | Pstr_value(_) => Js.log("Pstr_value")
    | Pstr_primitive(_) => Js.log("Pstr_primitive")
    | Pstr_type(_) => Js.log("Pstr_type")
    | Pstr_typext(_) => Js.log("Pstr_typext")
    | Pstr_exception(_) => Js.log("Pstr_exception")
    | Pstr_module(_) => Js.log("Pstr_module")
    | Pstr_recmodule(_) => Js.log("Pstr_recmodule")
    | Pstr_modtype(_) => Js.log("Pstr_modtype")
    | Pstr_open(_) => Js.log("Pstr_open")
    | Pstr_class(_) => Js.log("Pstr_class")
    | Pstr_class_type(_) => Js.log("Pstr_class_type")
    | Pstr_include(_) => Js.log("Pstr_include")
    | Pstr_attribute(_) => Js.log("Pstr_attribute")
    | Pstr_extension(_) => Js.log("Pstr_extension")
    }
  | None => ()
  };
};

/*
   Example 3: Translating between Reason and OCaml syntax
 */
Refmt_api.ML.print_implementation_with_comments(
  Format.str_formatter,
  astAndComments,
);
let ocamlCode = Format.flush_str_formatter();
Js.log("--- Example 3: Translating between Reason and OCaml syntax ---");
Js.log("Output OCaml code");
Js.log(ocamlCode);

/*
   Example 4: applying some PPX (in this case, reason-react ppx), including AST version transformation (with ocaml-migrate-parsetree)
 */
let reasonReactCode = "module Greeting = {
  [@react.component]
  let make = () => {
    <button> {React.string(\"Hello!\")} </button>
  };
};";
Js.log("--- Example 4: applying some PPX ---");
Js.log("Input code: ");
Js.log(reasonReactCode);
module Converter =
  Reason_toolchain_packed.Migrate_parsetree.Convert(
    Reason_toolchain_packed.Migrate_parsetree.OCaml_408,
    Reason_toolchain_packed.Migrate_parsetree.OCaml_406,
  );
module ConverterBack =
  Reason_toolchain_packed.Migrate_parsetree.Convert(
    Reason_toolchain_packed.Migrate_parsetree.OCaml_406,
    Reason_toolchain_packed.Migrate_parsetree.OCaml_408,
  );
let reasonParse = lexbuf =>
  Reason_toolchain_packed.Reason_toolchain.RE.implementation(lexbuf)
  ->Converter.copy_structure;
let lexbuf = Lexing.from_string(reasonReactCode);
let (ast, comments) = lexbuf |> Refmt_api.RE.implementation_with_comments;
let reactAst = lexbuf->reasonParse;
let newAst = Reason_react_ppx.rewrite_implementation(reactAst);
Refmt_api.RE.print_implementation_with_comments(
  Format.str_formatter,
  (newAst->ConverterBack.copy_structure, comments),
);
let reasonCode = Format.flush_str_formatter();
Js.log("Output code: ");
Js.log(reasonCode);
