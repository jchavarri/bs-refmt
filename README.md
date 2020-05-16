# bs-refmt

This is a (very rough) wrapper for [`refmt`](https://github.com/facebook/reason), the Reason parser / printer, packaged as a BuckleScript library.

## Install

In your BuckleScript project:

```bash
yarn add @jchavarri/bs-refmt
```

Then include the library in your bsconfig.json:

```
"bs-dependencies": ["@jchavarri/bs-refmt"],
```

Note: right now this package needs a patched version of BuckleScript to work. For details, see FAQ section below.

## Example usage

```reason
let reasonCode = "let t = Some(2)->Belt.Option.map(a => a * 2)";
let astAndComments =
  Lexing.from_string(reasonCode)
  |> Refmt_api.RE.implementation_with_comments;

Js.log("AST for: " ++ reasonCode);
Js.log(astAndComments);

let firstItem = structure->Belt.List.head;

let () =
  switch (firstItem) {
  | Some({pstr_desc, pstr_loc:_}) =>
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

/* Convert Reason back to OCaml syntax. */
Refmt_api.ML.print_implementation_with_comments(
  Format.str_formatter,
  astAndComments,
);
let ocamlCode = Format.flush_str_formatter();
Js.log(ocamlCode);
```

Check another example file in the [`example`](./example/src/Index.re) folder.

## FAQ

- What can this library be used for?

It could help to experiment or build applications that require to enter some text, and parse it into a "fully fleshed" OCaml AST (abstract syntax tree) to be processed, printed, displayed, manipulated visually or otherwise.

Printing code text from an AST also works.

- How is the file `Reason_toolchain_packed.ml` generated?

It's taken from Reason repo. Steps to generate it:

```bash
cd .. # one folder up from root folder
git clone https://github.com/jchavarri/reason/
git checkout bs-refmt
cd bspacks
./bspacks.js
cp output/4061/refmt.ml ../../bs-refmt/src/Reason_toolchain_packed.ml
```

- How is this different from `refmt.js` / npm `reason` package?

`refmt.js` (see [docs](https://github.com/facebook/reason/blob/master/USING_PARSER_PROGRAMMATICALLY.md)) is a packaging of refmt compiled with js_of_ocaml into JavaScript, but it can't be directly used from BuckleScript without bindings.

- How is this different from [`glennsl/bs-refmt`](https://github.com/glennsl/bs-refmt)?

`glennsl/bs-refmt` are the BuckleScript bindings to the JavaScript API exposed from refmt.js. It definitely _is_ a BuckleScript library, but the internals of the AST are opaque, only the surface API is typed (through the bindings).

On the other hand, this library gives full access to the internal AST of the resulting parsed tree.

- I don't see module X

For now, only a couple of modules are exposed (see `Refmt_api.ml`), but if you need access to more modules, please open an issue or a PR for it.
