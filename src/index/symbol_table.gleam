import glance
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import moonbit/ffi_meta.{type FfiMetadata}
import project/interface.{
  type PackageInterface, type ResolvedFunction, type ResolvedType,
  type ResolvedTypeDef, FnType, NamedType, TupleType, VariableType,
}
import project/prepass.{type ExternalType, type FfiKind, type PrepassResult}

/// Global symbol index for a Gleam package (and its staged/parsed modules).
pub type SymbolTable {
  SymbolTable(package_name: String, modules: Dict(String, ModuleSymbols))
}

/// Indexed symbols and import resolution tables for a single Gleam module.
pub type ModuleSymbols {
  ModuleSymbols(
    name: String,
    source: String,
    imports: List(ImportInfo),
    alias_to_module: Dict(String, String),
    unqualified_values: Dict(String, #(String, String)),
    unqualified_types: Dict(String, #(String, String)),
    types: Dict(String, TypeInfo),
    type_aliases: Dict(String, glance.TypeAlias),
    constructors: Dict(String, ConstructorInfo),
    functions: Dict(String, FunctionInfo),
    constants: Dict(String, ConstantInfo),
  )
}

/// Normalized import declaration metadata.
pub type ImportInfo {
  ImportInfo(
    module: String,
    alias: Option(String),
    unqualified_types: List(glance.UnqualifiedImport),
    unqualified_values: List(glance.UnqualifiedImport),
  )
}

/// A variant constructor field with AST and optional HM-resolved type.
pub type FieldInfo {
  FieldInfo(
    label: Option(String),
    ast_type: glance.Type,
    resolved_type: Option(ResolvedType),
  )
}

/// A single variant of a custom type.
pub type VariantInfo {
  VariantInfo(name: String, fields: List(FieldInfo))
}

/// Indexed metadata for a Gleam `CustomType`.
pub type TypeInfo {
  TypeInfo(
    module: String,
    name: String,
    publicity: glance.Publicity,
    opaque_: Bool,
    parameters: List(String),
    variants: List(VariantInfo),
    is_single_variant: Bool,
    shared_fields: Dict(String, ResolvedType),
    external_type: Option(ExternalType),
    has_function_field: Bool,
  )
}

/// Constructor lookup record linking a variant constructor to its parent type.
pub type ConstructorInfo {
  ConstructorInfo(
    module: String,
    type_name: String,
    variant_name: String,
    fields: List(FieldInfo),
  )
}

/// Indexed metadata for a function parameter.
pub type ParamInfo {
  ParamInfo(
    label: Option(String),
    name: glance.AssignmentName,
    ast_type: Option(glance.Type),
    resolved_type: Option(ResolvedType),
  )
}

/// Indexed metadata for a top-level function.
pub type FunctionInfo {
  FunctionInfo(
    module: String,
    name: String,
    publicity: glance.Publicity,
    arity: Int,
    parameters: List(ParamInfo),
    return_type: Option(ResolvedType),
    resolved: Option(ResolvedFunction),
    ffi: Option(FfiKind),
    has_erlang_or_js_external: Bool,
    has_gleam_body: Bool,
  )
}

/// Indexed metadata for a module constant.
pub type ConstantInfo {
  ConstantInfo(
    module: String,
    name: String,
    publicity: glance.Publicity,
    resolved_type: Option(ResolvedType),
  )
}

/// Build a project-wide `SymbolTable` from parsed modules, optional `PackageInterface`,
/// and `gekko.toml` / `gleam.toml` FFI overrides.
pub fn index_project(
  package_name: String,
  modules: List(#(String, glance.Module, PrepassResult)),
  pkg_interface: Option(PackageInterface),
  ffi_overrides: Dict(String, FfiKind),
) -> SymbolTable {
  let tagged =
    list.map(modules, fn(entry) {
      let #(mod_name, ast_mod, pre) = entry
      #(package_name, mod_name, ast_mod, pre)
    })
  index_project_with_packages(
    package_name,
    tagged,
    pkg_interface,
    ffi_overrides,
  )
}

/// Build a project-wide `SymbolTable` where each module carries its owning package name.
pub fn index_project_with_packages(
  root_package_name: String,
  package_modules: List(#(String, String, glance.Module, PrepassResult)),
  pkg_interface: Option(PackageInterface),
  ffi_overrides: Dict(String, FfiKind),
) -> SymbolTable {
  index_project_with_ffi_meta(
    root_package_name,
    package_modules,
    pkg_interface,
    ffi_overrides,
    ffi_meta.base_metadata(),
  )
}

/// Build a project-wide `SymbolTable` with explicit MoonBit FFI trait metadata.
pub fn index_project_with_ffi_meta(
  root_package_name: String,
  package_modules: List(#(String, String, glance.Module, PrepassResult)),
  pkg_interface: Option(PackageInterface),
  ffi_overrides: Dict(String, FfiKind),
  ffi_metadata: FfiMetadata,
) -> SymbolTable {
  let raw_modules =
    list.fold(package_modules, dict.new(), fn(acc, entry) {
      let #(pkg_name, mod_name, ast_mod, prepass_res) = entry
      let mod_iface = get_module_interface(pkg_interface, mod_name)
      let indexed =
        index_module(
          pkg_name,
          mod_name,
          ast_mod,
          prepass_res,
          mod_iface,
          ffi_overrides,
        )
      dict.insert(acc, mod_name, indexed)
    })

  let computed_modules =
    compute_transitive_type_flags(raw_modules, ffi_metadata)
  SymbolTable(package_name: root_package_name, modules: computed_modules)
}

/// Return True if a top-level definition has `@target(javascript)` and should
/// be skipped when compiling to MoonBit.
pub fn is_excluded_target(attributes: List(glance.Attribute)) -> Bool {
  list.any(attributes, fn(attr) {
    case attr.name, attr.arguments {
      "target", [glance.Variable(name: "javascript", ..)] -> True
      _, _ -> False
    }
  })
}

/// Look up a function in `current_module`, resolving module qualifiers and
/// unqualified imports.
pub fn lookup_function(
  table: SymbolTable,
  current_module: String,
  qualifier: Option(String),
  fn_name: String,
) -> Option(FunctionInfo) {
  case dict.get(table.modules, current_module) {
    Error(_) -> None
    Ok(mod_syms) ->
      case qualifier {
        Some(alias) ->
          case dict.get(mod_syms.alias_to_module, alias) {
            Ok(target_mod) ->
              lookup_function_in_module(table, target_mod, fn_name)
            Error(_) -> None
          }
        None ->
          case dict.get(mod_syms.functions, fn_name) {
            Ok(info) -> Some(info)
            Error(_) ->
              case dict.get(mod_syms.unqualified_values, fn_name) {
                Ok(#(target_mod, orig_name)) ->
                  lookup_function_in_module(table, target_mod, orig_name)
                Error(_) -> None
              }
          }
      }
  }
}

fn lookup_function_in_module(
  table: SymbolTable,
  module_name: String,
  fn_name: String,
) -> Option(FunctionInfo) {
  case dict.get(table.modules, module_name) {
    Ok(mod_syms) ->
      case dict.get(mod_syms.functions, fn_name) {
        Ok(info) -> Some(info)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

/// Look up a constructor in `current_module`, respecting optional module qualifier
/// (`mod.Ctor`) or unqualified imports (`import m.{Ctor}`).
pub fn lookup_constructor(
  table: SymbolTable,
  current_module: String,
  qualifier: Option(String),
  ctor_name: String,
) -> Option(ConstructorInfo) {
  case dict.get(table.modules, current_module) {
    Error(_) -> None
    Ok(mod_syms) ->
      case qualifier {
        Some(alias) ->
          case dict.get(mod_syms.alias_to_module, alias) {
            Ok(target_mod_name) ->
              lookup_constructor_in_module(table, target_mod_name, ctor_name)
            Error(_) -> None
          }
        None ->
          case dict.get(mod_syms.constructors, ctor_name) {
            Ok(info) -> Some(info)
            Error(_) ->
              case dict.get(mod_syms.unqualified_values, ctor_name) {
                Ok(#(target_mod_name, original_name)) ->
                  lookup_constructor_in_module(
                    table,
                    target_mod_name,
                    original_name,
                  )
                Error(_) -> None
              }
          }
      }
  }
}

/// Look up a custom type definition from `current_module`, resolving local types
/// and unqualified type imports.
pub fn lookup_type(
  table: SymbolTable,
  current_module: String,
  qualifier: Option(String),
  type_name: String,
) -> Option(TypeInfo) {
  case dict.get(table.modules, current_module) {
    Error(_) -> None
    Ok(mod_syms) ->
      case qualifier {
        Some(alias) ->
          case dict.get(mod_syms.alias_to_module, alias) {
            Ok(target_mod_name) ->
              lookup_type_in_module(table, target_mod_name, type_name)
            Error(_) -> None
          }
        None ->
          case dict.get(mod_syms.types, type_name) {
            Ok(info) -> Some(info)
            Error(_) ->
              case dict.get(mod_syms.unqualified_types, type_name) {
                Ok(#(target_mod_name, original_name)) ->
                  lookup_type_in_module(table, target_mod_name, original_name)
                Error(_) -> None
              }
          }
      }
  }
}

fn lookup_constructor_in_module(
  table: SymbolTable,
  module_name: String,
  ctor_name: String,
) -> Option(ConstructorInfo) {
  case dict.get(table.modules, module_name) {
    Ok(mod_syms) ->
      case dict.get(mod_syms.constructors, ctor_name) {
        Ok(info) -> Some(info)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

fn lookup_type_in_module(
  table: SymbolTable,
  module_name: String,
  type_name: String,
) -> Option(TypeInfo) {
  case dict.get(table.modules, module_name) {
    Ok(mod_syms) ->
      case dict.get(mod_syms.types, type_name) {
        Ok(info) -> Some(info)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

fn get_module_interface(
  pkg_interface: Option(PackageInterface),
  mod_name: String,
) -> Option(interface.ModuleInterface) {
  case pkg_interface {
    None -> None
    Some(iface) ->
      case dict.get(iface.modules, mod_name) {
        Ok(mod_iface) -> Some(mod_iface)
        Error(_) -> None
      }
  }
}

fn index_module(
  package_name: String,
  mod_name: String,
  ast_mod: glance.Module,
  prepass_res: PrepassResult,
  mod_iface: Option(interface.ModuleInterface),
  ffi_overrides: Dict(String, FfiKind),
) -> ModuleSymbols {
  let #(imports, alias_to_module, unqualified_values, unqualified_types) =
    index_imports(ast_mod.imports)

  let active_type_aliases =
    list.filter(ast_mod.type_aliases, fn(def) {
      !is_excluded_target(def.attributes)
    })
  let active_custom_types =
    list.filter(ast_mod.custom_types, fn(def) {
      !is_excluded_target(def.attributes)
    })
  let active_functions =
    list.filter(ast_mod.functions, fn(def) {
      !is_excluded_target(def.attributes)
    })
  let active_constants =
    list.filter(ast_mod.constants, fn(def) {
      !is_excluded_target(def.attributes)
    })

  let type_aliases =
    list.fold(active_type_aliases, dict.new(), fn(acc, def) {
      dict.insert(acc, def.definition.name, def.definition)
    })

  let #(types, constructors) =
    index_custom_types(
      package_name,
      mod_name,
      active_custom_types,
      prepass_res,
      mod_iface,
      alias_to_module,
      unqualified_types,
    )

  let functions =
    index_functions(
      package_name,
      mod_name,
      active_functions,
      prepass_res,
      mod_iface,
      ffi_overrides,
      alias_to_module,
      unqualified_types,
    )

  let constants =
    index_constants(
      package_name,
      mod_name,
      active_constants,
      mod_iface,
      alias_to_module,
      unqualified_types,
    )

  ModuleSymbols(
    name: mod_name,
    source: prepass_res.cleaned_source,
    imports:,
    alias_to_module:,
    unqualified_values:,
    unqualified_types:,
    types:,
    type_aliases:,
    constructors:,
    functions:,
    constants:,
  )
}

fn index_imports(
  import_defs: List(glance.Definition(glance.Import)),
) -> #(
  List(ImportInfo),
  Dict(String, String),
  Dict(String, #(String, String)),
  Dict(String, #(String, String)),
) {
  let #(rev_imports, alias_map, unqual_vals, unqual_types) =
    list.fold(
      import_defs,
      #([], dict.new(), dict.new(), dict.new()),
      fn(acc, def) {
        let #(imps, aliases, uvals, utypes) = acc
        let imp = def.definition
        let alias = resolve_import_alias(imp.module, imp.alias)
        let info =
          ImportInfo(
            module: imp.module,
            alias:,
            unqualified_types: imp.unqualified_types,
            unqualified_values: imp.unqualified_values,
          )
        let aliases = case alias {
          Some(a) -> dict.insert(aliases, a, imp.module)
          None -> aliases
        }
        let uvals =
          list.fold(imp.unqualified_values, uvals, fn(m, u) {
            let local_name = option.unwrap(u.alias, u.name)
            dict.insert(m, local_name, #(imp.module, u.name))
          })
        let utypes =
          list.fold(imp.unqualified_types, utypes, fn(m, u) {
            let local_name = option.unwrap(u.alias, u.name)
            dict.insert(m, local_name, #(imp.module, u.name))
          })
        #([info, ..imps], aliases, uvals, utypes)
      },
    )
  #(list.reverse(rev_imports), alias_map, unqual_vals, unqual_types)
}

fn resolve_import_alias(
  module_path: String,
  alias: Option(glance.AssignmentName),
) -> Option(String) {
  case alias {
    Some(glance.Named(name)) -> Some(name)
    Some(glance.Discarded(_)) -> None
    None ->
      module_path
      |> string.split("/")
      |> list.last
      |> option.from_result
  }
}

fn index_custom_types(
  package_name: String,
  mod_name: String,
  type_defs: List(glance.Definition(glance.CustomType)),
  prepass_res: PrepassResult,
  mod_iface: Option(interface.ModuleInterface),
  alias_to_module: Dict(String, String),
  unqualified_types: Dict(String, #(String, String)),
) -> #(Dict(String, TypeInfo), Dict(String, ConstructorInfo)) {
  let ext_type_map =
    list.fold(prepass_res.external_types, dict.new(), fn(acc, entry) {
      dict.insert(acc, entry.gleam_type_name, entry.target)
    })

  list.fold(type_defs, #(dict.new(), dict.new()), fn(acc, def) {
    let #(types_acc, ctors_acc) = acc
    let ct = def.definition
    let iface_type = lookup_iface_type(mod_iface, ct.name)
    let external_type = dict.get(ext_type_map, ct.name) |> option.from_result

    let variants =
      list.map(ct.variants, fn(variant) {
        let iface_variant = lookup_iface_variant(iface_type, variant.name)
        let fields =
          index_variant_fields(
            variant.fields,
            iface_variant,
            ct.parameters,
            package_name,
            mod_name,
            alias_to_module,
            unqualified_types,
          )
        VariantInfo(name: variant.name, fields:)
      })

    let is_single_variant = list.length(variants) == 1
    let shared_fields = compute_shared_fields(variants)

    let type_info =
      TypeInfo(
        module: mod_name,
        name: ct.name,
        publicity: ct.publicity,
        opaque_: ct.opaque_,
        parameters: ct.parameters,
        variants:,
        is_single_variant:,
        shared_fields:,
        external_type:,
        has_function_field: False,
      )

    let ctors_acc =
      list.fold(variants, ctors_acc, fn(m, v) {
        let ctor =
          ConstructorInfo(
            module: mod_name,
            type_name: ct.name,
            variant_name: v.name,
            fields: v.fields,
          )
        dict.insert(m, v.name, ctor)
      })

    #(dict.insert(types_acc, ct.name, type_info), ctors_acc)
  })
}

fn lookup_iface_type(
  mod_iface: Option(interface.ModuleInterface),
  type_name: String,
) -> Option(ResolvedTypeDef) {
  case mod_iface {
    None -> None
    Some(mi) ->
      case dict.get(mi.types, type_name) {
        Ok(td) -> Some(td)
        Error(_) -> None
      }
  }
}

fn lookup_iface_variant(
  iface_type: Option(ResolvedTypeDef),
  variant_name: String,
) -> Option(interface.ResolvedVariant) {
  case iface_type {
    None -> None
    Some(td) ->
      list.find(td.constructors, fn(v) { v.name == variant_name })
      |> option.from_result
  }
}

fn index_variant_fields(
  ast_fields: List(glance.VariantField),
  iface_variant: Option(interface.ResolvedVariant),
  type_params: List(String),
  package_name: String,
  mod_name: String,
  alias_to_module: Dict(String, String),
  unqualified_types: Dict(String, #(String, String)),
) -> List(FieldInfo) {
  let iface_fields = case iface_variant {
    Some(v) -> list.map(v.parameters, Some)
    None -> list.repeat(None, list.length(ast_fields))
  }

  let pairs = case list.length(iface_fields) == list.length(ast_fields) {
    True -> list.zip(ast_fields, iface_fields)
    False -> list.zip(ast_fields, list.repeat(None, list.length(ast_fields)))
  }

  list.map(pairs, fn(pair) {
    let #(ast_field, maybe_iface_field) = pair
    let #(label, ast_type) = case ast_field {
      glance.LabelledVariantField(item:, label:) -> #(Some(label), item)
      glance.UnlabelledVariantField(item:) -> #(None, item)
    }
    let resolved_type = case maybe_iface_field {
      Some(rf) -> Some(rf.type_)
      None ->
        Some(ast_type_to_resolved(
          ast_type,
          type_params,
          package_name,
          mod_name,
          alias_to_module,
          unqualified_types,
        ))
    }
    FieldInfo(label:, ast_type:, resolved_type:)
  })
}

fn compute_shared_fields(
  variants: List(VariantInfo),
) -> Dict(String, ResolvedType) {
  case variants {
    [] -> dict.new()
    [single] ->
      list.fold(single.fields, dict.new(), fn(acc, field) {
        case field.label, field.resolved_type {
          Some(lbl), Some(ty) -> dict.insert(acc, lbl, ty)
          _, _ -> acc
        }
      })
    [first, ..rest] ->
      list.fold(first.fields, dict.new(), fn(acc, field) {
        case field.label, field.resolved_type {
          Some(lbl), Some(ty) -> {
            let present_in_all =
              list.all(rest, fn(variant) {
                list.any(variant.fields, fn(other) {
                  other.label == Some(lbl) && other.resolved_type == Some(ty)
                })
              })
            case present_in_all {
              True -> dict.insert(acc, lbl, ty)
              False -> acc
            }
          }
          _, _ -> acc
        }
      })
  }
}

fn index_functions(
  package_name: String,
  mod_name: String,
  fn_defs: List(glance.Definition(glance.Function)),
  prepass_res: PrepassResult,
  mod_iface: Option(interface.ModuleInterface),
  ffi_overrides: Dict(String, FfiKind),
  alias_to_module: Dict(String, String),
  unqualified_types: Dict(String, #(String, String)),
) -> Dict(String, FunctionInfo) {
  list.fold(fn_defs, dict.new(), fn(acc, def) {
    let func = def.definition
    let resolved_fn = case mod_iface {
      None -> None
      Some(mi) ->
        case dict.get(mi.functions, func.name) {
          Ok(rf) -> Some(rf)
          Error(_) -> None
        }
    }

    let params =
      build_param_infos(
        func.parameters,
        resolved_fn,
        package_name,
        mod_name,
        alias_to_module,
        unqualified_types,
      )

    let return_type = case resolved_fn {
      Some(rf) -> Some(rf.return)
      None ->
        option.map(func.return, fn(ret_ast) {
          ast_type_to_resolved(
            ret_ast,
            [],
            package_name,
            mod_name,
            alias_to_module,
            unqualified_types,
          )
        })
    }

    let ffi =
      resolve_function_ffi(
        package_name,
        mod_name,
        func.name,
        prepass_res,
        ffi_overrides,
      )

    let has_ext_attr =
      list.any(def.attributes, fn(attr) {
        case attr.name, attr.arguments {
          "external", [glance.Variable(name: "erlang", ..), ..]
          | "external", [glance.Variable(name: "javascript", ..), ..]
          -> True
          _, _ -> False
        }
      })

    let has_iface_ext = case resolved_fn {
      Some(rf) ->
        rf.implementations.uses_erlang_externals
        || rf.implementations.uses_javascript_externals
      None -> False
    }

    let info =
      FunctionInfo(
        module: mod_name,
        name: func.name,
        publicity: func.publicity,
        arity: list.length(func.parameters),
        parameters: params,
        return_type:,
        resolved: resolved_fn,
        ffi:,
        has_erlang_or_js_external: has_ext_attr || has_iface_ext,
        has_gleam_body: func.body != [],
      )
    dict.insert(acc, func.name, info)
  })
}

fn build_param_infos(
  ast_params: List(glance.FunctionParameter),
  resolved_fn: Option(ResolvedFunction),
  package_name: String,
  mod_name: String,
  alias_to_module: Dict(String, String),
  unqualified_types: Dict(String, #(String, String)),
) -> List(ParamInfo) {
  let iface_params = case resolved_fn {
    Some(rf) -> list.map(rf.parameters, Some)
    None -> list.repeat(None, list.length(ast_params))
  }
  let pairs = case list.length(iface_params) == list.length(ast_params) {
    True -> list.zip(ast_params, iface_params)
    False -> list.zip(ast_params, list.repeat(None, list.length(ast_params)))
  }

  list.map(pairs, fn(pair) {
    let #(ast_p, maybe_iface_p) = pair
    let resolved_type = case maybe_iface_p {
      Some(rp) -> Some(rp.type_)
      None ->
        option.map(ast_p.type_, fn(t) {
          ast_type_to_resolved(
            t,
            [],
            package_name,
            mod_name,
            alias_to_module,
            unqualified_types,
          )
        })
    }
    ParamInfo(
      label: ast_p.label,
      name: ast_p.name,
      ast_type: ast_p.type_,
      resolved_type:,
    )
  })
}

/// Resolve any MoonBit FFI mapping configured in `ffi_overrides` or `@external(moonbit, ...)` pragmas.
pub fn resolve_function_ffi(
  package_name: String,
  mod_name: String,
  fn_name: String,
  prepass_res: PrepassResult,
  ffi_overrides: Dict(String, FfiKind),
) -> Option(FfiKind) {
  let candidate_keys = [
    package_name <> ":" <> mod_name <> "." <> fn_name,
    package_name <> "." <> mod_name <> "." <> fn_name,
    mod_name <> "." <> fn_name,
  ]
  case list.find_map(candidate_keys, fn(k) { dict.get(ffi_overrides, k) }) {
    Ok(kind) -> Some(kind)
    Error(_) -> {
      let matching =
        list.filter(prepass_res.ffi_entries, fn(e) {
          e.module == mod_name && e.function_name == fn_name
        })
      let raw = list.find(matching, fn(e) { e.source == prepass.RawAttribute })
      case raw {
        Ok(e) -> Some(e.kind)
        Error(_) ->
          case list.last(matching) {
            Ok(e) -> Some(e.kind)
            Error(_) -> None
          }
      }
    }
  }
}

fn index_constants(
  package_name: String,
  mod_name: String,
  const_defs: List(glance.Definition(glance.Constant)),
  mod_iface: Option(interface.ModuleInterface),
  alias_to_module: Dict(String, String),
  unqualified_types: Dict(String, #(String, String)),
) -> Dict(String, ConstantInfo) {
  list.fold(const_defs, dict.new(), fn(acc, def) {
    let c = def.definition
    let resolved_type = case mod_iface {
      Some(mi) ->
        case dict.get(mi.constants, c.name) {
          Ok(rc) -> Some(rc.type_)
          Error(_) ->
            option.map(c.annotation, fn(t) {
              ast_type_to_resolved(
                t,
                [],
                package_name,
                mod_name,
                alias_to_module,
                unqualified_types,
              )
            })
        }
      None ->
        option.map(c.annotation, fn(t) {
          ast_type_to_resolved(
            t,
            [],
            package_name,
            mod_name,
            alias_to_module,
            unqualified_types,
          )
        })
    }
    let info =
      ConstantInfo(
        module: mod_name,
        name: c.name,
        publicity: c.publicity,
        resolved_type:,
      )
    dict.insert(acc, c.name, info)
  })
}

fn ast_type_to_resolved(
  ty: glance.Type,
  type_params: List(String),
  package_name: String,
  current_module: String,
  alias_to_module: Dict(String, String),
  unqualified_types: Dict(String, #(String, String)),
) -> ResolvedType {
  case ty {
    glance.NamedType(name:, module: mod_opt, parameters:, ..) -> {
      let #(resolved_pkg, resolved_mod, resolved_name) = case mod_opt {
        Some(alias) -> {
          let target_mod =
            dict.get(alias_to_module, alias)
            |> result_unwrap(alias)
          #(package_name, target_mod, name)
        }
        None ->
          case dict.get(unqualified_types, name) {
            Ok(#(target_mod, orig_name)) -> #(
              package_name,
              target_mod,
              orig_name,
            )
            Error(_) ->
              case is_builtin_prelude_type(name) {
                True -> #("", "gleam", name)
                False -> #(package_name, current_module, name)
              }
          }
      }
      let resolved_params =
        list.map(parameters, fn(p) {
          ast_type_to_resolved(
            p,
            type_params,
            package_name,
            current_module,
            alias_to_module,
            unqualified_types,
          )
        })
      NamedType(
        name: resolved_name,
        package: resolved_pkg,
        module: resolved_mod,
        parameters: resolved_params,
      )
    }

    glance.TupleType(elements:, ..) ->
      TupleType(
        elements: list.map(elements, fn(el) {
          ast_type_to_resolved(
            el,
            type_params,
            package_name,
            current_module,
            alias_to_module,
            unqualified_types,
          )
        }),
      )

    glance.FunctionType(parameters:, return:, ..) ->
      FnType(
        parameters: list.map(parameters, fn(p) {
          ast_type_to_resolved(
            p,
            type_params,
            package_name,
            current_module,
            alias_to_module,
            unqualified_types,
          )
        }),
        return: ast_type_to_resolved(
          return,
          type_params,
          package_name,
          current_module,
          alias_to_module,
          unqualified_types,
        ),
      )

    glance.VariableType(name:, ..) | glance.HoleType(name:, ..) ->
      VariableType(id: find_type_param_index(type_params, name, 0))
  }
}

fn find_type_param_index(
  params: List(String),
  target: String,
  idx: Int,
) -> Int {
  case params {
    [] -> idx
    [head, ..tail] ->
      case head == target {
        True -> idx
        False -> find_type_param_index(tail, target, idx + 1)
      }
  }
}

fn is_builtin_prelude_type(name: String) -> Bool {
  case name {
    "Int"
    | "Float"
    | "String"
    | "Bool"
    | "Nil"
    | "List"
    | "Result"
    | "BitArray"
    | "UtfCodepoint" -> True
    _ -> False
  }
}

fn result_unwrap(res: Result(a, b), default: a) -> a {
  case res {
    Ok(v) -> v
    Error(_) -> default
  }
}

fn compute_transitive_type_flags(
  modules: Dict(String, ModuleSymbols),
  ffi_metadata: FfiMetadata,
) -> Dict(String, ModuleSymbols) {
  let all_types =
    dict.fold(modules, dict.new(), fn(acc, mod_name, mod_syms) {
      dict.fold(mod_syms.types, acc, fn(inner, type_name, type_info) {
        dict.insert(inner, #(mod_name, type_name), #(
          type_info.external_type,
          type_info.variants,
        ))
      })
    })

  dict.map_values(modules, fn(mod_name, mod_syms) {
    let updated_types =
      dict.map_values(mod_syms.types, fn(type_name, type_info) {
        let has_fn =
          type_key_has_function_field(
            #(mod_name, type_name),
            all_types,
            ffi_metadata,
            set.new(),
          )
        TypeInfo(..type_info, has_function_field: has_fn)
      })
    ModuleSymbols(..mod_syms, types: updated_types)
  })
}

fn type_key_has_function_field(
  key: #(String, String),
  all_types: Dict(#(String, String), #(Option(ExternalType), List(VariantInfo))),
  ffi_metadata: FfiMetadata,
  visited: Set(#(String, String)),
) -> Bool {
  case set.contains(visited, key) {
    True -> False
    False ->
      case dict.get(all_types, key) {
        Error(_) -> False
        Ok(#(Some(ext), _)) ->
          !ffi_meta.is_derivable(ffi_metadata, ext.package, ext.type_name)
        Ok(#(None, variants)) -> {
          let next_visited = set.insert(visited, key)
          list.any(variants, fn(variant) {
            list.any(variant.fields, fn(field) {
              case field.resolved_type {
                Some(ty) ->
                  resolved_type_has_function(
                    ty,
                    all_types,
                    ffi_metadata,
                    next_visited,
                  )
                None -> False
              }
            })
          })
        }
      }
  }
}

fn resolved_type_has_function(
  ty: ResolvedType,
  all_types: Dict(#(String, String), #(Option(ExternalType), List(VariantInfo))),
  ffi_metadata: FfiMetadata,
  visited: Set(#(String, String)),
) -> Bool {
  case ty {
    FnType(_, _) -> True
    VariableType(_) -> False
    TupleType(elements:) ->
      list.any(elements, fn(el) {
        resolved_type_has_function(el, all_types, ffi_metadata, visited)
      })
    NamedType(name:, module:, parameters:, ..) ->
      list.any(parameters, fn(p) {
        resolved_type_has_function(p, all_types, ffi_metadata, visited)
      })
      || type_key_has_function_field(
        #(module, name),
        all_types,
        ffi_metadata,
        visited,
      )
  }
}

/// Compute the set of function names in `ast_mod` that are reachable from
/// public functions, `main`, `*_test` tests, and public constants, stopping at
/// functions mapped to a MoonBit FFI target.
pub fn reachable_private_functions(
  ast_mod: glance.Module,
  functions: Dict(String, FunctionInfo),
) -> Set(String) {
  let active_fns =
    ast_mod.functions
    |> list.filter(fn(def) { !is_excluded_target(def.attributes) })
    |> list.map(fn(def) { def.definition })

  let fn_map =
    list.fold(active_fns, dict.new(), fn(acc, f) { dict.insert(acc, f.name, f) })

  let active_consts =
    ast_mod.constants
    |> list.filter(fn(def) { !is_excluded_target(def.attributes) })
    |> list.map(fn(def) { def.definition })

  let const_map =
    list.fold(active_consts, dict.new(), fn(acc, c) {
      dict.insert(acc, c.name, c.value)
    })

  let fn_roots =
    list.filter_map(active_fns, fn(f) {
      let is_root =
        f.publicity == glance.Public
        || f.name == "main"
        || string.ends_with(f.name, "_test")
      case is_root {
        True -> Ok(f.name)
        False -> Error(Nil)
      }
    })

  let const_roots =
    list.filter_map(active_consts, fn(c) {
      case c.publicity {
        glance.Public -> Ok(c.name)
        glance.Private -> Error(Nil)
      }
    })

  bfs_reachable_fns(
    fn_roots,
    const_roots,
    set.from_list(fn_roots),
    set.from_list(const_roots),
    fn_map,
    const_map,
    functions,
  )
}

fn bfs_reachable_fns(
  fn_queue: List(String),
  const_queue: List(String),
  visited_fns: Set(String),
  visited_consts: Set(String),
  fn_map: Dict(String, glance.Function),
  const_map: Dict(String, glance.Expression),
  functions: Dict(String, FunctionInfo),
) -> Set(String) {
  case fn_queue, const_queue {
    [], [] -> visited_fns
    [fn_name, ..rest_fns], _ -> {
      let has_ffi = case dict.get(functions, fn_name) {
        Ok(info) -> info.ffi != None
        Error(_) -> False
      }
      case has_ffi, dict.get(fn_map, fn_name) {
        False, Ok(f) -> {
          let refs = collect_stmts_var_refs(f.body, set.new())
          enqueue_refs(
            refs,
            rest_fns,
            const_queue,
            visited_fns,
            visited_consts,
            fn_map,
            const_map,
            functions,
          )
        }
        _, _ ->
          bfs_reachable_fns(
            rest_fns,
            const_queue,
            visited_fns,
            visited_consts,
            fn_map,
            const_map,
            functions,
          )
      }
    }
    [], [const_name, ..rest_consts] ->
      case dict.get(const_map, const_name) {
        Ok(expr) -> {
          let refs = collect_expr_var_refs(expr, set.new())
          enqueue_refs(
            refs,
            [],
            rest_consts,
            visited_fns,
            visited_consts,
            fn_map,
            const_map,
            functions,
          )
        }
        Error(_) ->
          bfs_reachable_fns(
            [],
            rest_consts,
            visited_fns,
            visited_consts,
            fn_map,
            const_map,
            functions,
          )
      }
  }
}

fn enqueue_refs(
  refs: Set(String),
  fn_queue: List(String),
  const_queue: List(String),
  visited_fns: Set(String),
  visited_consts: Set(String),
  fn_map: Dict(String, glance.Function),
  const_map: Dict(String, glance.Expression),
  functions: Dict(String, FunctionInfo),
) -> Set(String) {
  let #(next_fn_q, next_const_q, next_vfns, next_vconsts) =
    set.fold(
      refs,
      #(fn_queue, const_queue, visited_fns, visited_consts),
      fn(acc, name) {
        let #(fq, cq, vf, vc) = acc
        let #(fq1, vf1) = case
          dict.has_key(fn_map, name) && !set.contains(vf, name)
        {
          True -> #([name, ..fq], set.insert(vf, name))
          False -> #(fq, vf)
        }
        case dict.has_key(const_map, name) && !set.contains(vc, name) {
          True -> #(fq1, [name, ..cq], vf1, set.insert(vc, name))
          False -> #(fq1, cq, vf1, vc)
        }
      },
    )
  bfs_reachable_fns(
    next_fn_q,
    next_const_q,
    next_vfns,
    next_vconsts,
    fn_map,
    const_map,
    functions,
  )
}

fn collect_stmts_var_refs(
  stmts: List(glance.Statement),
  acc: Set(String),
) -> Set(String) {
  list.fold(stmts, acc, collect_stmt_var_refs)
}

fn collect_stmt_var_refs(
  acc: Set(String),
  stmt: glance.Statement,
) -> Set(String) {
  case stmt {
    glance.Expression(expr) -> collect_expr_var_refs(expr, acc)
    glance.Use(function:, ..) -> collect_expr_var_refs(function, acc)
    glance.Assignment(kind:, value:, ..) -> {
      let acc1 = collect_expr_var_refs(value, acc)
      case kind {
        glance.LetAssert(message: Some(msg)) -> collect_expr_var_refs(msg, acc1)
        _ -> acc1
      }
    }
    glance.Assert(expression:, message:, ..) -> {
      let acc1 = collect_expr_var_refs(expression, acc)
      case message {
        Some(msg) -> collect_expr_var_refs(msg, acc1)
        None -> acc1
      }
    }
  }
}

fn collect_field_var_refs(
  fields: List(glance.Field(glance.Expression)),
  acc: Set(String),
) -> Set(String) {
  list.fold(fields, acc, fn(a, f) {
    case f {
      glance.LabelledField(item:, ..) | glance.UnlabelledField(item:) ->
        collect_expr_var_refs(item, a)
      glance.ShorthandField(label:, ..) -> set.insert(a, label)
    }
  })
}

fn collect_expr_var_refs(
  expr: glance.Expression,
  acc: Set(String),
) -> Set(String) {
  case expr {
    glance.Int(..) | glance.Float(..) | glance.String(..) -> acc
    glance.Variable(name:, ..) -> set.insert(acc, name)
    glance.NegateInt(value:, ..) | glance.NegateBool(value:, ..) ->
      collect_expr_var_refs(value, acc)
    glance.Block(statements:, ..) -> collect_stmts_var_refs(statements, acc)
    glance.Panic(message:, ..) | glance.Todo(message:, ..) ->
      case message {
        Some(msg) -> collect_expr_var_refs(msg, acc)
        None -> acc
      }
    glance.Tuple(elements:, ..) ->
      list.fold(elements, acc, fn(a, e) { collect_expr_var_refs(e, a) })
    glance.List(elements:, rest:, ..) -> {
      let acc1 =
        list.fold(elements, acc, fn(a, e) { collect_expr_var_refs(e, a) })
      case rest {
        Some(r) -> collect_expr_var_refs(r, acc1)
        None -> acc1
      }
    }
    glance.Fn(body:, ..) -> collect_stmts_var_refs(body, acc)
    glance.RecordUpdate(record:, fields:, ..) -> {
      let acc1 = collect_expr_var_refs(record, acc)
      list.fold(fields, acc1, fn(a, f) {
        case f.item {
          Some(item) -> collect_expr_var_refs(item, a)
          None -> set.insert(a, f.label)
        }
      })
    }
    glance.FieldAccess(container:, ..) -> collect_expr_var_refs(container, acc)
    glance.Call(function:, arguments:, ..) ->
      collect_field_var_refs(arguments, collect_expr_var_refs(function, acc))
    glance.TupleIndex(tuple:, ..) -> collect_expr_var_refs(tuple, acc)
    glance.FnCapture(function:, arguments_before:, arguments_after:, ..) ->
      collect_expr_var_refs(function, acc)
      |> collect_field_var_refs(arguments_before, _)
      |> collect_field_var_refs(arguments_after, _)
    glance.BitString(segments:, ..) ->
      list.fold(segments, acc, fn(a, seg) {
        let #(inner, opts) = seg
        let a1 = collect_expr_var_refs(inner, a)
        list.fold(opts, a1, fn(a2, opt) {
          case opt {
            glance.SizeValueOption(size_expr) ->
              collect_expr_var_refs(size_expr, a2)
            _ -> a2
          }
        })
      })
    glance.Case(subjects:, clauses:, ..) -> {
      let acc1 =
        list.fold(subjects, acc, fn(a, s) { collect_expr_var_refs(s, a) })
      list.fold(clauses, acc1, fn(a, clause) {
        let a1 = case clause.guard {
          Some(g) -> collect_expr_var_refs(g, a)
          None -> a
        }
        collect_expr_var_refs(clause.body, a1)
      })
    }
    glance.BinaryOperator(left:, right:, ..) ->
      collect_expr_var_refs(right, collect_expr_var_refs(left, acc))
    glance.Echo(expression:, message:, ..) -> {
      let acc1 = case expression {
        Some(e) -> collect_expr_var_refs(e, acc)
        None -> acc
      }
      case message {
        Some(m) -> collect_expr_var_refs(m, acc1)
        None -> acc1
      }
    }
  }
}
