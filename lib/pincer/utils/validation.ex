defmodule Pincer.Utils.Validation do
  @moduledoc """
  Small changeset-like validation for plain structs.

  Pincer uses embedded SQLite and plain structs for its persistence models.
  This module keeps the familiar `changeset.valid?`, `changeset.errors`,
  `cast/3`, `validate_required/2`, `validate_inclusion/3`,
  `validate_number/3`, `apply_changes/1` and `get_field/2` API without
  pulling in `Ecto`.
  """

  defstruct data: %{}, changes: %{}, errors: [], valid?: true

  @type t :: %__MODULE__{
          data: struct(),
          changes: map(),
          errors: keyword(),
          valid?: boolean()
        }

  @doc "Builds a validation context for `struct` from allowed `attrs` keys."
  @spec cast(struct(), map(), [atom()]) :: t()
  def cast(%_{} = struct, attrs, fields) when is_map(attrs) and is_list(fields) do
    changes =
      Enum.reduce(fields, %{}, fn field, acc ->
        case fetch_attr(attrs, field) do
          {:ok, value} -> Map.put(acc, field, value)
          :error -> acc
        end
      end)

    %__MODULE__{data: struct, changes: changes}
  end

  @doc "Adds a validation error for `field`."
  @spec add_error(t(), atom(), String.t(), keyword()) :: t()
  def add_error(%__MODULE__{} = changeset, field, message, opts \\ []) when is_binary(message) do
    %{changeset | errors: [{field, {message, opts}} | changeset.errors], valid?: false}
  end

  @doc "Validates that fields are present and not empty strings."
  @spec validate_required(t(), [atom()]) :: t()
  def validate_required(%__MODULE__{} = changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      if blank?(get_field(acc, field)) do
        add_error(acc, field, "can't be blank", validation: :required)
      else
        acc
      end
    end)
  end

  @doc "Validates that a field belongs to `values`."
  @spec validate_inclusion(t(), atom(), [term()]) :: t()
  def validate_inclusion(%__MODULE__{} = changeset, field, values) do
    if Enum.member?(values, get_field(changeset, field)) do
      changeset
    else
      add_error(changeset, field, "is invalid", validation: :inclusion, enum: values)
    end
  end

  @doc "Validates numeric bounds for a field."
  @spec validate_number(t(), atom(), keyword()) :: t()
  def validate_number(%__MODULE__{} = changeset, field, opts) do
    case get_field(changeset, field) do
      nil ->
        changeset

      value when is_number(value) ->
        Enum.reduce(opts, changeset, fn
          {:greater_than_or_equal_to, min}, acc ->
            if value >= min,
              do: acc,
              else:
                add_error(
                  acc,
                  field,
                  "must be greater than or equal to #{min}",
                  validation: :number,
                  kind: :greater_than_or_equal_to,
                  number: min
                )

          {:less_than_or_equal_to, max}, acc ->
            if value <= max,
              do: acc,
              else:
                add_error(
                  acc,
                  field,
                  "must be less than or equal to #{max}",
                  validation: :number,
                  kind: :less_than_or_equal_to,
                  number: max
                )

          _other, acc ->
            acc
        end)

      _other ->
        add_error(changeset, field, "is invalid", validation: :number)
    end
  end

  @doc "Returns the changed value for `field`, if any."
  @spec get_change(t(), atom()) :: term()
  def get_change(%__MODULE__{changes: changes}, field), do: Map.get(changes, field)

  @doc "Returns the effective field value (change first, then struct data)."
  @spec get_field(t(), atom()) :: term()
  def get_field(%__MODULE__{changes: changes, data: data}, field) do
    case Map.fetch(changes, field) do
      {:ok, value} -> value
      :error -> Map.get(data, field)
    end
  end

  @doc "Applies the changes to the underlying struct."
  @spec apply_changes(t()) :: struct()
  def apply_changes(%__MODULE__{data: data, changes: changes}) do
    struct(data.__struct__, Map.merge(Map.from_struct(data), changes))
  end

  defp fetch_attr(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Map.fetch(attrs, Atom.to_string(field))
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
