import gleam/option.{type Option, None, Some}

/// Lightweight specification of a built-in `gleam/*` constructor.
pub type BuiltinCtorSpec {
  BuiltinCtorSpec(
    type_name: String,
    variant_name: String,
    field_labels: List(Option(String)),
  )
}

/// Lightweight specification of a built-in `gleam/*` function.
pub type BuiltinFnSpec {
  BuiltinFnSpec(name: String, param_labels: List(Option(String)))
}

/// Lightweight specification of a built-in `gleam/*` shim module.
pub type BuiltinModuleSpec {
  BuiltinModuleSpec(
    module_name: String,
    constructors: List(BuiltinCtorSpec),
    functions: List(BuiltinFnSpec),
  )
}

/// Return exact constructor and function label metadata for all `gleam/*`
/// stdlib and `gleam_json` modules implemented by `stdlib_runtime`.
pub fn builtin_module_specs() -> List(BuiltinModuleSpec) {
  [
    order_spec(),
    bool_spec(),
    pair_spec(),
    option_spec(),
    result_spec(),
    int_spec(),
    float_spec(),
    string_spec(),
    list_spec(),
    dict_spec(),
    io_spec(),
    string_tree_spec(),
    bytes_tree_spec(),
    bit_array_spec(),
    dynamic_spec(),
    decode_spec(),
    json_spec(),
  ]
}

fn order_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(
    module_name: "gleam/order",
    constructors: [
      BuiltinCtorSpec("Order", "Lt", []),
      BuiltinCtorSpec("Order", "Eq", []),
      BuiltinCtorSpec("Order", "Gt", []),
    ],
    functions: [
      BuiltinFnSpec("negate", [None]),
      BuiltinFnSpec("to_int", [None]),
      BuiltinFnSpec("compare", [None, Some("with")]),
      BuiltinFnSpec("reverse", [None]),
      BuiltinFnSpec("break_tie", [Some("in"), Some("with")]),
      BuiltinFnSpec("lazy_break_tie", [Some("in"), Some("with")]),
    ],
  )
}

fn bool_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(module_name: "gleam/bool", constructors: [], functions: [
    BuiltinFnSpec("and", [None, None]),
    BuiltinFnSpec("or", [None, None]),
    BuiltinFnSpec("negate", [None]),
    BuiltinFnSpec("nor", [None, None]),
    BuiltinFnSpec("nand", [None, None]),
    BuiltinFnSpec("exclusive_or", [None, None]),
    BuiltinFnSpec("exclusive_nor", [None, None]),
    BuiltinFnSpec("to_string", [None]),
    BuiltinFnSpec("guard", [Some("when"), Some("return"), Some("otherwise")]),
    BuiltinFnSpec("lazy_guard", [
      Some("when"),
      Some("return"),
      Some("otherwise"),
    ]),
  ])
}

fn pair_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(module_name: "gleam/pair", constructors: [], functions: [
    BuiltinFnSpec("first", [None]),
    BuiltinFnSpec("second", [None]),
    BuiltinFnSpec("swap", [None]),
    BuiltinFnSpec("map_first", [Some("of"), Some("with")]),
    BuiltinFnSpec("map_second", [Some("of"), Some("with")]),
    BuiltinFnSpec("new", [None, None]),
  ])
}

fn option_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(
    module_name: "gleam/option",
    constructors: [
      BuiltinCtorSpec("Option", "Some", [None]),
      BuiltinCtorSpec("Option", "None", []),
    ],
    functions: [
      BuiltinFnSpec("all", [None]),
      BuiltinFnSpec("is_some", [None]),
      BuiltinFnSpec("is_none", [None]),
      BuiltinFnSpec("to_result", [None, None]),
      BuiltinFnSpec("from_result", [None]),
      BuiltinFnSpec("unwrap", [None, Some("or")]),
      BuiltinFnSpec("lazy_unwrap", [None, Some("or")]),
      BuiltinFnSpec("map", [Some("over"), Some("with")]),
      BuiltinFnSpec("flatten", [None]),
      BuiltinFnSpec("then", [None, Some("apply")]),
      BuiltinFnSpec("or", [None, None]),
      BuiltinFnSpec("lazy_or", [None, None]),
      BuiltinFnSpec("values", [None]),
    ],
  )
}

fn result_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(module_name: "gleam/result", constructors: [], functions: [
    BuiltinFnSpec("is_ok", [None]),
    BuiltinFnSpec("is_error", [None]),
    BuiltinFnSpec("map", [Some("over"), Some("with")]),
    BuiltinFnSpec("map_error", [Some("over"), Some("with")]),
    BuiltinFnSpec("flatten", [None]),
    BuiltinFnSpec("try", [None, Some("apply")]),
    BuiltinFnSpec("unwrap", [None, Some("or")]),
    BuiltinFnSpec("lazy_unwrap", [None, Some("or")]),
    BuiltinFnSpec("unwrap_error", [None, Some("or")]),
    BuiltinFnSpec("unwrap_both", [None]),
    BuiltinFnSpec("or", [None, None]),
    BuiltinFnSpec("lazy_or", [None, None]),
    BuiltinFnSpec("all", [None]),
    BuiltinFnSpec("partition", [None]),
    BuiltinFnSpec("replace", [None, None]),
    BuiltinFnSpec("replace_error", [None, None]),
    BuiltinFnSpec("values", [None]),
    BuiltinFnSpec("try_recover", [None, Some("with")]),
  ])
}

fn int_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(module_name: "gleam/int", constructors: [], functions: [
    BuiltinFnSpec("absolute_value", [None]),
    BuiltinFnSpec("power", [None, Some("of")]),
    BuiltinFnSpec("square_root", [None]),
    BuiltinFnSpec("parse", [None]),
    BuiltinFnSpec("base_parse", [None, None]),
    BuiltinFnSpec("to_string", [None]),
    BuiltinFnSpec("to_base_string", [None, None]),
    BuiltinFnSpec("to_base2", [None]),
    BuiltinFnSpec("to_base8", [None]),
    BuiltinFnSpec("to_base16", [None]),
    BuiltinFnSpec("to_base36", [None]),
    BuiltinFnSpec("to_float", [None]),
    BuiltinFnSpec("clamp", [None, Some("min"), Some("max")]),
    BuiltinFnSpec("compare", [None, Some("with")]),
    BuiltinFnSpec("min", [None, None]),
    BuiltinFnSpec("max", [None, None]),
    BuiltinFnSpec("is_even", [None]),
    BuiltinFnSpec("is_odd", [None]),
    BuiltinFnSpec("negate", [None]),
    BuiltinFnSpec("sum", [None]),
    BuiltinFnSpec("product", [None]),
    BuiltinFnSpec("divide", [None, Some("by")]),
    BuiltinFnSpec("remainder", [None, Some("by")]),
    BuiltinFnSpec("modulo", [None, Some("by")]),
    BuiltinFnSpec("floor_divide", [None, Some("by")]),
    BuiltinFnSpec("add", [None, None]),
    BuiltinFnSpec("multiply", [None, None]),
    BuiltinFnSpec("subtract", [None, None]),
    BuiltinFnSpec("bitwise_and", [None, None]),
    BuiltinFnSpec("bitwise_not", [None]),
    BuiltinFnSpec("bitwise_or", [None, None]),
    BuiltinFnSpec("bitwise_exclusive_or", [None, None]),
    BuiltinFnSpec("bitwise_shift_left", [None, None]),
    BuiltinFnSpec("bitwise_shift_right", [None, None]),
    BuiltinFnSpec("random", [None]),
    BuiltinFnSpec("range", [Some("from"), Some("to"), Some("with"), Some("run")]),
  ])
}

fn float_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(module_name: "gleam/float", constructors: [], functions: [
    BuiltinFnSpec("parse", [None]),
    BuiltinFnSpec("to_string", [None]),
    BuiltinFnSpec("clamp", [None, Some("min"), Some("max")]),
    BuiltinFnSpec("compare", [None, Some("with")]),
    BuiltinFnSpec("loosely_compare", [None, Some("with"), Some("tolerating")]),
    BuiltinFnSpec("loosely_equals", [None, Some("with"), Some("tolerating")]),
    BuiltinFnSpec("min", [None, None]),
    BuiltinFnSpec("max", [None, None]),
    BuiltinFnSpec("ceiling", [None]),
    BuiltinFnSpec("floor", [None]),
    BuiltinFnSpec("round", [None]),
    BuiltinFnSpec("truncate", [None]),
    BuiltinFnSpec("absolute_value", [None]),
    BuiltinFnSpec("power", [None, Some("of")]),
    BuiltinFnSpec("square_root", [None]),
    BuiltinFnSpec("negate", [None]),
    BuiltinFnSpec("sum", [None]),
    BuiltinFnSpec("product", [None]),
    BuiltinFnSpec("modulo", [None, Some("by")]),
    BuiltinFnSpec("divide", [None, Some("by")]),
    BuiltinFnSpec("add", [None, None]),
    BuiltinFnSpec("multiply", [None, None]),
    BuiltinFnSpec("subtract", [None, None]),
    BuiltinFnSpec("random", []),
  ])
}

fn string_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(module_name: "gleam/string", constructors: [], functions: [
    BuiltinFnSpec("is_empty", [None]),
    BuiltinFnSpec("length", [None]),
    BuiltinFnSpec("reverse", [None]),
    BuiltinFnSpec("replace", [Some("in"), Some("each"), Some("with")]),
    BuiltinFnSpec("lowercase", [None]),
    BuiltinFnSpec("uppercase", [None]),
    BuiltinFnSpec("compare", [None, None]),
    BuiltinFnSpec("slice", [Some("from"), Some("at_index"), Some("length")]),
    BuiltinFnSpec("crop", [Some("from"), Some("before")]),
    BuiltinFnSpec("drop_start", [Some("from"), Some("up_to")]),
    BuiltinFnSpec("drop_end", [Some("from"), Some("up_to")]),
    BuiltinFnSpec("contains", [Some("does"), Some("contain")]),
    BuiltinFnSpec("starts_with", [None, None]),
    BuiltinFnSpec("ends_with", [None, None]),
    BuiltinFnSpec("split", [None, Some("on")]),
    BuiltinFnSpec("split_once", [None, Some("on")]),
    BuiltinFnSpec("append", [Some("to"), Some("suffix")]),
    BuiltinFnSpec("concat", [None]),
    BuiltinFnSpec("repeat", [None, Some("times")]),
    BuiltinFnSpec("join", [None, Some("with")]),
    BuiltinFnSpec("pad_start", [None, Some("to"), Some("with")]),
    BuiltinFnSpec("pad_end", [None, Some("to"), Some("with")]),
    BuiltinFnSpec("trim", [None]),
    BuiltinFnSpec("trim_start", [None]),
    BuiltinFnSpec("trim_end", [None]),
    BuiltinFnSpec("pop_grapheme", [None]),
    BuiltinFnSpec("to_graphemes", [None]),
    BuiltinFnSpec("to_option", [None]),
    BuiltinFnSpec("first", [None]),
    BuiltinFnSpec("last", [None]),
    BuiltinFnSpec("capitalise", [None]),
    BuiltinFnSpec("inspect", [None]),
    BuiltinFnSpec("byte_size", [None]),
    BuiltinFnSpec("remove_prefix", [Some("from"), Some("matching")]),
    BuiltinFnSpec("remove_suffix", [Some("from"), Some("matching")]),
  ])
}

fn list_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(
    module_name: "gleam/list",
    constructors: [
      BuiltinCtorSpec("ContinueOrStop", "Continue", [None]),
      BuiltinCtorSpec("ContinueOrStop", "Stop", [None]),
    ],
    functions: [
      BuiltinFnSpec("length", [Some("of")]),
      BuiltinFnSpec("count", [None, Some("where")]),
      BuiltinFnSpec("reverse", [None]),
      BuiltinFnSpec("is_empty", [None]),
      BuiltinFnSpec("contains", [None, Some("any")]),
      BuiltinFnSpec("first", [None]),
      BuiltinFnSpec("rest", [None]),
      BuiltinFnSpec("group", [None, Some("by")]),
      BuiltinFnSpec("filter", [None, Some("keeping")]),
      BuiltinFnSpec("filter_map", [None, Some("with")]),
      BuiltinFnSpec("map", [None, Some("with")]),
      BuiltinFnSpec("map2", [None, None, Some("with")]),
      BuiltinFnSpec("map_fold", [Some("over"), Some("from"), Some("with")]),
      BuiltinFnSpec("index_map", [None, Some("with")]),
      BuiltinFnSpec("try_map", [Some("over"), Some("with")]),
      BuiltinFnSpec("drop", [Some("from"), Some("up_to")]),
      BuiltinFnSpec("take", [Some("from"), Some("up_to")]),
      BuiltinFnSpec("new", []),
      BuiltinFnSpec("wrap", [None]),
      BuiltinFnSpec("append", [None, None]),
      BuiltinFnSpec("prepend", [Some("to"), Some("this")]),
      BuiltinFnSpec("flatten", [None]),
      BuiltinFnSpec("flat_map", [Some("over"), Some("with")]),
      BuiltinFnSpec("fold", [Some("over"), Some("from"), Some("with")]),
      BuiltinFnSpec("fold_right", [Some("over"), Some("from"), Some("with")]),
      BuiltinFnSpec("index_fold", [Some("over"), Some("from"), Some("with")]),
      BuiltinFnSpec("try_fold", [Some("over"), Some("from"), Some("with")]),
      BuiltinFnSpec("fold_until", [Some("over"), Some("from"), Some("with")]),
      BuiltinFnSpec("find", [Some("in"), Some("one_that")]),
      BuiltinFnSpec("find_map", [Some("in"), Some("with")]),
      BuiltinFnSpec("all", [Some("in"), Some("satisfying")]),
      BuiltinFnSpec("any", [Some("in"), Some("satisfying")]),
      BuiltinFnSpec("zip", [None, Some("with")]),
      BuiltinFnSpec("strict_zip", [None, Some("with")]),
      BuiltinFnSpec("unzip", [None]),
      BuiltinFnSpec("intersperse", [None, Some("with")]),
      BuiltinFnSpec("unique", [None]),
      BuiltinFnSpec("sort", [None, Some("by")]),
      BuiltinFnSpec("range", [Some("from"), Some("to")]),
      BuiltinFnSpec("repeat", [Some("item"), Some("times")]),
      BuiltinFnSpec("split", [Some("list"), Some("at")]),
      BuiltinFnSpec("split_while", [Some("list"), Some("satisfying")]),
      BuiltinFnSpec("key_find", [Some("in"), Some("find")]),
      BuiltinFnSpec("key_filter", [Some("in"), Some("find")]),
      BuiltinFnSpec("key_pop", [None, None]),
      BuiltinFnSpec("key_set", [None, None, None]),
      BuiltinFnSpec("each", [None, None]),
      BuiltinFnSpec("try_each", [Some("over"), Some("with")]),
      BuiltinFnSpec("partition", [None, Some("with")]),
      BuiltinFnSpec("drop_while", [Some("in"), Some("satisfying")]),
      BuiltinFnSpec("take_while", [Some("in"), Some("satisfying")]),
      BuiltinFnSpec("chunk", [Some("in"), Some("by")]),
      BuiltinFnSpec("sized_chunk", [Some("in"), Some("into")]),
      BuiltinFnSpec("reduce", [Some("over"), Some("with")]),
      BuiltinFnSpec("scan", [Some("over"), Some("from"), Some("with")]),
      BuiltinFnSpec("last", [None]),
    ],
  )
}

fn dict_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(module_name: "gleam/dict", constructors: [], functions: [
    BuiltinFnSpec("size", [None]),
    BuiltinFnSpec("is_empty", [None]),
    BuiltinFnSpec("to_list", [None]),
    BuiltinFnSpec("from_list", [None]),
    BuiltinFnSpec("has_key", [None, None]),
    BuiltinFnSpec("new", []),
    BuiltinFnSpec("get", [None, None]),
    BuiltinFnSpec("insert", [Some("into"), Some("for"), Some("insert")]),
    BuiltinFnSpec("map_values", [Some("in"), Some("with")]),
    BuiltinFnSpec("keys", [None]),
    BuiltinFnSpec("values", [None]),
    BuiltinFnSpec("filter", [Some("in"), Some("keeping")]),
    BuiltinFnSpec("take", [Some("from"), Some("keeping")]),
    BuiltinFnSpec("merge", [Some("into"), Some("from")]),
    BuiltinFnSpec("delete", [Some("from"), Some("delete")]),
    BuiltinFnSpec("drop", [Some("from"), Some("drop")]),
    BuiltinFnSpec("upsert", [Some("in"), Some("update"), Some("with")]),
    BuiltinFnSpec("fold", [Some("over"), Some("from"), Some("with")]),
    BuiltinFnSpec("each", [None, None]),
    BuiltinFnSpec("combine", [None, None, Some("with")]),
    BuiltinFnSpec("group", [None, None]),
  ])
}

fn io_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(module_name: "gleam/io", constructors: [], functions: [
    BuiltinFnSpec("print", [None]),
    BuiltinFnSpec("print_error", [None]),
    BuiltinFnSpec("println", [None]),
    BuiltinFnSpec("println_error", [None]),
  ])
}

fn string_tree_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(
    module_name: "gleam/string_tree",
    constructors: [],
    functions: [
      BuiltinFnSpec("new", []),
      BuiltinFnSpec("prepend", [Some("to"), Some("prefix")]),
      BuiltinFnSpec("append", [Some("to"), Some("suffix")]),
      BuiltinFnSpec("prepend_tree", [Some("to"), Some("prefix")]),
      BuiltinFnSpec("append_tree", [Some("to"), Some("suffix")]),
      BuiltinFnSpec("from_strings", [None]),
      BuiltinFnSpec("concat", [None]),
      BuiltinFnSpec("from_string", [None]),
      BuiltinFnSpec("to_string", [None]),
      BuiltinFnSpec("byte_size", [None]),
      BuiltinFnSpec("join", [None, Some("with")]),
      BuiltinFnSpec("lowercase", [None]),
      BuiltinFnSpec("uppercase", [None]),
      BuiltinFnSpec("reverse", [None]),
      BuiltinFnSpec("split", [None, Some("on")]),
      BuiltinFnSpec("replace", [Some("in"), Some("each"), Some("with")]),
      BuiltinFnSpec("is_equal", [None, None]),
      BuiltinFnSpec("is_empty", [None]),
    ],
  )
}

fn bytes_tree_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(
    module_name: "gleam/bytes_tree",
    constructors: [],
    functions: [
      BuiltinFnSpec("new", []),
      BuiltinFnSpec("prepend", [Some("to"), Some("prefix")]),
      BuiltinFnSpec("append", [Some("to"), Some("suffix")]),
      BuiltinFnSpec("prepend_tree", [Some("to"), Some("prefix")]),
      BuiltinFnSpec("append_tree", [Some("to"), Some("suffix")]),
      BuiltinFnSpec("prepend_string", [Some("to"), Some("prefix")]),
      BuiltinFnSpec("append_string", [Some("to"), Some("suffix")]),
      BuiltinFnSpec("concat", [None]),
      BuiltinFnSpec("concat_bit_arrays", [None]),
      BuiltinFnSpec("from_string", [None]),
      BuiltinFnSpec("from_string_tree", [None]),
      BuiltinFnSpec("from_bit_array", [None]),
      BuiltinFnSpec("to_bit_array", [None]),
      BuiltinFnSpec("byte_size", [None]),
    ],
  )
}

fn bit_array_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(
    module_name: "gleam/bit_array",
    constructors: [],
    functions: [
      BuiltinFnSpec("from_string", [None]),
      BuiltinFnSpec("bit_size", [None]),
      BuiltinFnSpec("byte_size", [None]),
      BuiltinFnSpec("pad_to_bytes", [None]),
      BuiltinFnSpec("append", [Some("to"), Some("suffix")]),
      BuiltinFnSpec("slice", [Some("from"), Some("at"), Some("take")]),
      BuiltinFnSpec("is_utf8", [None]),
      BuiltinFnSpec("to_string", [None]),
      BuiltinFnSpec("concat", [None]),
      BuiltinFnSpec("base16_encode", [None]),
      BuiltinFnSpec("base16_decode", [None]),
      BuiltinFnSpec("inspect", [None]),
      BuiltinFnSpec("compare", [None, Some("with")]),
      BuiltinFnSpec("starts_with", [None, None]),
    ],
  )
}

fn dynamic_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(module_name: "gleam/dynamic", constructors: [], functions: [
    BuiltinFnSpec("classify", [None]),
    BuiltinFnSpec("bool", [None]),
    BuiltinFnSpec("string", [None]),
    BuiltinFnSpec("float", [None]),
    BuiltinFnSpec("int", [None]),
    BuiltinFnSpec("bit_array", [None]),
    BuiltinFnSpec("list", [None]),
    BuiltinFnSpec("array", [None]),
    BuiltinFnSpec("properties", [None]),
    BuiltinFnSpec("nil", []),
  ])
}

fn decode_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(
    module_name: "gleam/dynamic/decode",
    constructors: [
      BuiltinCtorSpec("DecodeError", "DecodeError", [
        Some("expected"),
        Some("found"),
        Some("path"),
      ]),
    ],
    functions: [
      BuiltinFnSpec("subfield", [None, None, None]),
      BuiltinFnSpec("run", [None, None]),
      BuiltinFnSpec("at", [None, None]),
      BuiltinFnSpec("success", [None]),
      BuiltinFnSpec("decode_error", [Some("expected"), Some("found")]),
      BuiltinFnSpec("field", [None, None, None]),
      BuiltinFnSpec("optional_field", [None, None, None, None]),
      BuiltinFnSpec("optionally_at", [None, None, None]),
      BuiltinFnSpec("list", [Some("of")]),
      BuiltinFnSpec("dict", [None, None]),
      BuiltinFnSpec("optional", [None]),
      BuiltinFnSpec("map", [None, None]),
      BuiltinFnSpec("map_errors", [None, None]),
      BuiltinFnSpec("collapse_errors", [None, None]),
      BuiltinFnSpec("then", [None, None]),
      BuiltinFnSpec("one_of", [None, Some("or")]),
      BuiltinFnSpec("failure", [None, Some("expected")]),
      BuiltinFnSpec("new_primitive_decoder", [None, None]),
      BuiltinFnSpec("recursive", [None]),
    ],
  )
}

fn json_spec() -> BuiltinModuleSpec {
  BuiltinModuleSpec(
    module_name: "gleam/json",
    constructors: [
      BuiltinCtorSpec("DecodeError", "UnexpectedEndOfInput", []),
      BuiltinCtorSpec("DecodeError", "UnexpectedByte", [None]),
      BuiltinCtorSpec("DecodeError", "UnexpectedSequence", [None]),
      BuiltinCtorSpec("DecodeError", "UnableToDecode", [None]),
    ],
    functions: [
      BuiltinFnSpec("parse", [Some("from"), Some("using")]),
      BuiltinFnSpec("parse_bits", [Some("from"), Some("using")]),
      BuiltinFnSpec("to_string", [None]),
      BuiltinFnSpec("to_string_tree", [None]),
      BuiltinFnSpec("string", [None]),
      BuiltinFnSpec("bool", [None]),
      BuiltinFnSpec("int", [None]),
      BuiltinFnSpec("float", [None]),
      BuiltinFnSpec("null", []),
      BuiltinFnSpec("nullable", [Some("from"), Some("of")]),
      BuiltinFnSpec("object", [None]),
      BuiltinFnSpec("array", [Some("from"), Some("of")]),
      BuiltinFnSpec("preprocessed_array", [None]),
      BuiltinFnSpec("dict", [None, None, None]),
    ],
  )
}
