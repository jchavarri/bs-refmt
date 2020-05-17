# bs-refmt

[`refmt`](https://github.com/facebook/reason), the Reason parser / printer, packaged as a BuckleScript library.

## Install

In your BuckleScript project:

```bash
yarn add @jchavarri/bs-refmt
```

Then include the library in your bsconfig.json:

```
"bs-dependencies": ["@jchavarri/bs-refmt"],
```

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

Printing code text from an AST also works. As well as "in-browser" ppxs.

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

- I don't see module X

For now, only a couple of modules are exposed (see `Refmt_api.ml`) for simplicity.
To access all modules reach for the bspacked module `Reason_toolchain_packed`.

## Previous work

- `refmt.js` / npm `reason` package?

`refmt.js` (see [docs](https://github.com/facebook/reason/blob/master/USING_PARSER_PROGRAMMATICALLY.md)) is a packaging of refmt compiled with js_of_ocaml into JavaScript.

- [`glennsl/bs-refmt`](https://github.com/glennsl/bs-refmt)

`glennsl/bs-refmt` are the BuckleScript bindings to the JavaScript API exposed from refmt.js. It _is_ a BuckleScript library like this one, but the internals of the AST are opaque, one can only get types for the data that is explicitly typed in the bindings.

The main difference between previous approaches and this iteration is that now there is full access to the types of the resulting parsed tree.

## Thanks

This library is a very thin wrapper, building on top of the effort done by the projects mentioned above, as well as the shoulders of giants below:

- [The OCaml compiler](https://github.com/ocaml/ocaml)
- [The Reason parser / printer](https://github.com/facebook/reason), aka refmt
- [The BuckleScript compiler](https://github.com/BuckleScript/bucklescript/) and [bspack](https://github.com/BuckleScript/bucklescript/blob/676c4b5d605061f7b479388b3ba37ede01722783/jscomp/main/bspack_main.ml)
