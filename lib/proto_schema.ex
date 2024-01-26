defmodule ProtoSchema do
  @moduledoc """
  Documentation for `ProtoSchema`.
  """
  alias Protobuf.FieldProps

  @float_types ~w(float double)a
  @integer_types ~w(int32 int64 uint32 uint64 sint32 int64 ixed32 ixed64 fixed32 fixed64)a

  defmacro __using__(mod: {:__aliases__, _, mod}) do
    proto_mod = Module.concat(mod)

    schema_from_proto(proto_mod, __CALLER__.module)
  end

  def schema_from_proto(mod, base_schema) do
    embeds =
      mod
      |> traverse_fields(&embeds_from_proto(&1, &2, base_schema))
      |> Enum.uniq()

    fields = traverse_fields(mod, &fields_from_proto(&1, &2, mod, base_schema))

    quote do
      use Ecto.Schema
      alias __MODULE__
      import ExGreens.Protobuf.Schema
      import Ecto.Changeset

      Module.register_attribute(__MODULE__, :allowed_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :required_fields, accumulate: true)
      Module.register_attribute(__MODULE__, :embedded_fields, accumulate: true)

      unquote_splicing(embeds)

      @primary_key false
      embedded_schema do
        unquote(fields)
      end

      @doc false
      def changeset(%__MODULE__{} = str, attrs \\ %{}) do
        str
        |> cast(attrs, @allowed_fields)
        |> validate_required(@required_fields)
        |> (&Enum.reduce(@embedded_fields, &1, fn field, changeset ->
              cast_embed(changeset, field)
            end)).()
      end
    end
  end

  def traverse_fields(mod, fun) do
    mod.__message_props__.field_props
    |> Map.values()
    |> Enum.reduce(
      [],
      fun
    )
  end

  def fields_from_proto(
        %FieldProps{
          name_atom: name,
          type: type,
          embedded?: false,
          required?: required?,
          repeated?: repeated?
        } = props,
        acc,
        _mod,
        _base_schema
      ) do
    [
      quote do
        Module.put_attribute(__MODULE__, :allowed_fields, unquote(name))

        if unquote(required?) do
          Module.put_attribute(__MODULE__, :required_fields, unquote(name))
        end

        if unquote(repeated?) do
          field(
            unquote(name),
            {:array, unquote(type_to_ecto(type))},
            unquote(opts_to_ecto(props))
          )
        else
          field(unquote(name), unquote(type_to_ecto(type)), unquote(opts_to_ecto(props)))
        end
      end
      | acc
    ]
  end

  def fields_from_proto(
        %FieldProps{
          name_atom: name,
          type: type,
          embedded?: true,
          repeated?: repeated?
        },
        acc,
        mod,
        base_schema
      ) do
    [
      quote do
        Module.put_attribute(__MODULE__, :embedded_fields, unquote(name))

        if unquote(repeated?) do
          embeds_many(unquote(name), unquote(proto_module_to_schema(type, mod, base_schema)),
            on_replace: :delete
          )
        else
          embeds_one(unquote(name), unquote(proto_module_to_schema(type, mod, base_schema)),
            on_replace: :delete
          )
        end
      end
      | acc
    ]
  end

  def fields_from_proto(_, acc, _, _), do: acc

  def embeds_from_proto(
        %FieldProps{
          type: type,
          embedded?: true
        },
        acc,
        schema
      ) do
    mod =
      type
      |> Module.split()
      |> List.last()
      |> (&Module.concat(schema, &1)).()

    [
      quote do
        defmodule unquote(mod) do
          unquote(schema_from_proto(type, mod))
        end

        alias unquote(mod)
      end
      | acc
    ]
  end

  def embeds_from_proto(_, acc, _), do: acc

  def type_to_ecto(t) when t in @integer_types, do: :integer
  def type_to_ecto(t) when t in @float_types, do: :float
  def type_to_ecto(:string), do: :string
  def type_to_ecto(:binary), do: :binary
  def type_to_ecto(:bool), do: :boolean
  def type_to_ecto({:enum, _}), do: Ecto.Enum

  def opts_to_ecto(%FieldProps{default: default, type: {:enum, mod} = type}) do
    values =
      mod.mapping()
      |> Map.to_list()

    default =
      case default do
        nil ->
          default_from_type(type)

        default ->
          default
      end

    [values: values, default: default]
  end

  def opts_to_ecto(%FieldProps{default: nil, type: type}) do
    [default: default_from_type(type)]
  end

  def opts_to_ecto(%FieldProps{default: default}), do: [default: default]

  def default_from_type(t) when t in @integer_types, do: 0
  def default_from_type(t) when t in @float_types, do: 0.0
  def default_from_type(:string), do: ""
  def default_from_type(:binary), do: <<>>
  def default_from_type(:bool), do: false

  def default_from_type({:enum, type}) do
    type.mapping()
    |> Map.to_list()
    |> hd()
    |> elem(0)
  end

  def default_from_type(_), do: nil

  def proto_module_to_schema(type, _mod, base_schema) do
    type
    |> Module.split()
    |> List.last()
    |> (&Module.concat(base_schema, &1)).()
  end
end
