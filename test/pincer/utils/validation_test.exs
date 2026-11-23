defmodule Pincer.Utils.ValidationTest do
  use ExUnit.Case, async: true

  alias Pincer.Utils.Validation

  defmodule Model do
    defstruct name: nil, status: "new", score: 0.5
  end

  test "cast/apply_changes applies only allowed fields" do
    changeset =
      Model
      |> struct()
      |> Validation.cast(%{name: "job", status: "done", ignored: true}, [:name, :status])
      |> Validation.validate_required([:name])

    assert changeset.valid?
    assert Validation.get_field(changeset, :name) == "job"
    assert Validation.get_field(changeset, :score) == 0.5
    assert %Model{name: "job", status: "done", score: 0.5} = Validation.apply_changes(changeset)
  end

  test "required, inclusion and number validations accumulate errors" do
    changeset =
      struct(Model)
      |> Validation.cast(%{status: "bogus", score: 2.0}, [:status, :score])
      |> Validation.validate_required([:name])
      |> Validation.validate_inclusion(:status, ["new", "done"])
      |> Validation.validate_number(:score, less_than_or_equal_to: 1.0)

    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:name]
    assert {"is invalid", _} = changeset.errors[:status]
    assert {"must be less than or equal to 1.0", _} = changeset.errors[:score]
  end

  test "accepts string keys and treats empty strings as blank" do
    changeset =
      struct(Model)
      |> Validation.cast(%{"name" => ""}, [:name])
      |> Validation.validate_required([:name])

    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:name]
  end
end
