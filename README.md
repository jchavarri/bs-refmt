

# bs-refmt

This is a (very rough) wrapper of the whole [`refmt`](https://github.com/facebook/reason), packaged as a BuckleScript library.

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
[%bs.raw {|require("./index.css")|}];

let ast_and_comments =
  Lexing.from_string("let f = a => a->Belt.Option.map(f => f * 2);")
  |> Refmt_api.RE.implementation_with_comments;

Js.log(ast_and_comments);

/* Convert Reason back to OCaml syntax. */
let ocaml_syntax = {
  Refmt_api.ML.print_implementation_with_comments(
    Format.str_formatter,
    ast_and_comments,
  );
  let ocaml_code = Format.flush_str_formatter();
  Js.log(ocaml_code);
};
```

Check another example file in the [`example`](./example/Index.re) folder.

## What can this library be used for?

It could help to build experiments or applications that require to enter some text, and parse it into a "fully fleshed" OCaml AST (abstract syntax tree) to be processed, printed, displayed or manipulated visually or otherwise.

The other process also works (printing code text from an AST).

## FAQ

- How is the main `Js_refmt_compiler.ml` generated?

It's taken from BuckleScript repo, where [some ninja script](https://github.com/jchavarri/bucklescript/blob/7aada144d89b31f8b17c0db26fcc4d9596c4050d/jscomp/snapshot.ninja#L61-L63) generates it.

- I get "TypeError: name is undefined" at runtime

Right now, this library requires a patched version of BuckleScript to work. To make it work:

```bash
# In another folder
git clone https://github.com/jchavarri/bucklescript
cd bucklescript
git checkout -b compile-refmt-all origin/compile-refmt-all
git submodule update --init && node scripts/buildocaml.js
./scripts/ninja.js config && ./scripts/ninja.js build
node scripts/install.js
yarn link
```

Then in your project folder:
```
yarn link bs-platform
```
