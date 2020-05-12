[%bs.raw {|require("./index.css")|}];

let ast_and_comments =
  Lexing.from_string("let f = a => a->Belt.Option.map(f => f * 2);")
  |> Refmt_api.RE.implementation_with_comments;

Js.log(ast_and_comments);

/* Convert Reason back to OCaml syntax. That'll show these Reason users! */
let ocaml_syntax = {
  Refmt_api.ML.print_implementation_with_comments(
    Format.str_formatter,
    ast_and_comments,
  );
  Format.flush_str_formatter();
};

