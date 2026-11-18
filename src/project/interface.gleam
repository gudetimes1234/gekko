import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

/// Hindley-Milner resolved type from `gleam export package-interface`.
pub type ResolvedType {
  NamedType(
    name: String,
    package: String,
    module: String,
    parameters: List(ResolvedType),
  )
  TupleType(elements: List(ResolvedType))
  FnType(parameters: List(ResolvedType), return: ResolvedType)
  VariableType(id: Int)
}

/// Resolved function parameter.
pub type ResolvedParam {
  ResolvedParam(label: Option(String), type_: ResolvedType)
}

/// Platform implementation metadata exported by `gleam export package-interface`.
pub type Implementations {
  Implementations(
    gleam: Bool,
    uses_erlang_externals: Bool,
    uses_javascript_externals: Bool,
  )
}

/// Resolved function signature.
pub type ResolvedFunction {
  ResolvedFunction(
    parameters: List(ResolvedParam),
    return: ResolvedType,
    implementations: Implementations,
  )
}

/// Resolved constructor field of a custom type variant.
pub type ResolvedVariantField {
  ResolvedVariantField(label: Option(String), type_: ResolvedType)
}

/// Resolved variant constructor of a custom type.
pub type ResolvedVariant {
  ResolvedVariant(name: String, parameters: List(ResolvedVariantField))
}

/// Resolved custom type definition.
pub type ResolvedTypeDef {
  ResolvedTypeDef(parameters: Int, constructors: List(ResolvedVariant))
}

/// Resolved type alias definition.
pub type ResolvedTypeAlias {
  ResolvedTypeAlias(parameters: Int, alias: ResolvedType)
}

/// Resolved module constant definition.
pub type ResolvedConstant {
  ResolvedConstant(type_: ResolvedType, implementations: Implementations)
}

/// Decoded interface of a single Gleam module.
pub type ModuleInterface {
  ModuleInterface(
    type_aliases: Dict(String, ResolvedTypeAlias),
    types: Dict(String, ResolvedTypeDef),
    constants: Dict(String, ResolvedConstant),
    functions: Dict(String, ResolvedFunction),
  )
}

/// Decoded package interface returned by `gleam export package-interface`.
pub type PackageInterface {
  PackageInterface(
    name: String,
    version: String,
    modules: Dict(String, ModuleInterface),
  )
}

/// Decode `gleam export package-interface` JSON into a `PackageInterface`.
pub fn decode_package_interface(
  json_str: String,
) -> Result(PackageInterface, String) {
  json.parse(from: json_str, using: package_interface_decoder())
  |> result.map_error(format_json_error)
}

fn package_interface_decoder() -> Decoder(PackageInterface) {
  use name <- decode.field("name", decode.string)
  use version <- decode.field("version", decode.string)
  use modules <- decode.field(
    "modules",
    decode.dict(decode.string, module_interface_decoder()),
  )
  decode.success(PackageInterface(name:, version:, modules:))
}

fn module_interface_decoder() -> Decoder(ModuleInterface) {
  use type_aliases <- decode.field(
    "type-aliases",
    decode.dict(decode.string, type_alias_decoder()),
  )
  use types <- decode.field(
    "types",
    decode.dict(decode.string, type_def_decoder()),
  )
  use constants <- decode.field(
    "constants",
    decode.dict(decode.string, constant_decoder()),
  )
  use functions <- decode.field(
    "functions",
    decode.dict(decode.string, function_decoder()),
  )
  decode.success(ModuleInterface(type_aliases:, types:, constants:, functions:))
}

fn type_alias_decoder() -> Decoder(ResolvedTypeAlias) {
  use parameters <- decode.field("parameters", decode.int)
  use alias <- decode.field("alias", resolved_type_decoder())
  decode.success(ResolvedTypeAlias(parameters:, alias:))
}

fn type_def_decoder() -> Decoder(ResolvedTypeDef) {
  use parameters <- decode.field("parameters", decode.int)
  use constructors <- decode.field(
    "constructors",
    decode.list(variant_decoder()),
  )
  decode.success(ResolvedTypeDef(parameters:, constructors:))
}

fn variant_decoder() -> Decoder(ResolvedVariant) {
  use name <- decode.field("name", decode.string)
  use parameters <- decode.field(
    "parameters",
    decode.list(variant_field_decoder()),
  )
  decode.success(ResolvedVariant(name:, parameters:))
}

fn variant_field_decoder() -> Decoder(ResolvedVariantField) {
  use label <- decode.field("label", decode.optional(decode.string))
  use type_ <- decode.field("type", resolved_type_decoder())
  decode.success(ResolvedVariantField(label:, type_:))
}

fn constant_decoder() -> Decoder(ResolvedConstant) {
  use type_ <- decode.field("type", resolved_type_decoder())
  use implementations <- decode.optional_field(
    "implementations",
    Implementations(True, False, False),
    implementations_decoder(),
  )
  decode.success(ResolvedConstant(type_:, implementations:))
}

fn function_decoder() -> Decoder(ResolvedFunction) {
  use parameters <- decode.field("parameters", decode.list(param_decoder()))
  use return <- decode.field("return", resolved_type_decoder())
  use implementations <- decode.optional_field(
    "implementations",
    Implementations(True, False, False),
    implementations_decoder(),
  )
  decode.success(ResolvedFunction(parameters:, return:, implementations:))
}

fn param_decoder() -> Decoder(ResolvedParam) {
  use label <- decode.field("label", decode.optional(decode.string))
  use type_ <- decode.field("type", resolved_type_decoder())
  decode.success(ResolvedParam(label:, type_:))
}

fn implementations_decoder() -> Decoder(Implementations) {
  use gleam <- decode.field("gleam", decode.bool)
  use uses_erlang_externals <- decode.field(
    "uses-erlang-externals",
    decode.bool,
  )
  use uses_javascript_externals <- decode.field(
    "uses-javascript-externals",
    decode.bool,
  )
  decode.success(Implementations(
    gleam:,
    uses_erlang_externals:,
    uses_javascript_externals:,
  ))
}

fn resolved_type_decoder() -> Decoder(ResolvedType) {
  use <- decode.recursive
  use kind <- decode.field("kind", decode.string)
  case kind {
    "named" -> {
      use name <- decode.field("name", decode.string)
      use package <- decode.field("package", decode.string)
      use module <- decode.field("module", decode.string)
      use parameters <- decode.field(
        "parameters",
        decode.list(resolved_type_decoder()),
      )
      decode.success(NamedType(name:, package:, module:, parameters:))
    }
    "tuple" -> {
      use elements <- decode.field(
        "elements",
        decode.list(resolved_type_decoder()),
      )
      decode.success(TupleType(elements:))
    }
    "fn" -> {
      use parameters <- decode.field(
        "parameters",
        decode.list(resolved_type_decoder()),
      )
      use return <- decode.field("return", resolved_type_decoder())
      decode.success(FnType(parameters:, return:))
    }
    "variable" -> {
      use id <- decode.field("id", decode.int)
      decode.success(VariableType(id:))
    }
    other ->
      decode.failure(
        VariableType(0),
        "ResolvedType kind (named|tuple|fn|variable), got " <> other,
      )
  }
}

fn format_json_error(err: json.DecodeError) -> String {
  case err {
    json.UnexpectedEndOfInput -> "JSON decode error: unexpected end of input"
    json.UnexpectedByte(byte) -> "JSON decode error: unexpected byte " <> byte
    json.UnexpectedSequence(seq) ->
      "JSON decode error: unexpected sequence " <> seq
    json.UnableToDecode(errors) -> {
      let details =
        errors
        |> list.map(fn(e) {
          let path = case e.path {
            [] -> "<root>"
            parts -> string.join(parts, ".")
          }
          path <> ": expected " <> e.expected <> ", found " <> e.found
        })
        |> string.join("; ")
      "JSON schema decode error: " <> details
    }
  }
}
