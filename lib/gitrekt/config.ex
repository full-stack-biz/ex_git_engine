defmodule GitRekt.Config do
  @moduledoc """
  Configuration for GitRekt resource limits and security settings.

  Configuration can be overridden in the application environment:

      config :gitrekt,
        max_object_size: 100 * 1024 * 1024,
        max_pack_size: 1 * 1024 * 1024 * 1024
  """

  @doc """
  Returns the maximum allowed size for a single Git object in bytes.

  Default: 100 MB

  Prevents resource exhaustion from malicious PACK files claiming huge objects.
  """
  @spec max_object_size :: pos_integer
  def max_object_size do
    Application.get_env(:gitrekt, :max_object_size, 100 * 1024 * 1024)
  end

  @doc """
  Returns the maximum allowed size for a PACK file in bytes.

  Default: 1 GB

  Prevents resource exhaustion from extremely large PACK files.
  """
  @spec max_pack_size :: pos_integer
  def max_pack_size do
    Application.get_env(:gitrekt, :max_pack_size, 1 * 1024 * 1024 * 1024)
  end
end
