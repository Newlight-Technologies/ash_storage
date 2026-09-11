defmodule AshStorage.AnalyzerScratch do
  @moduledoc false

  # Infrastructure only: callers own analyzer execution and result persistence.
  # Never expose uploaded bytes in a shared temporary directory.
  def with_file(bytes, callback) when is_binary(bytes) and is_function(callback, 1) do
    with {:ok, directory} <- create_directory(4) do
      try do
        with :ok <- File.chmod(directory, 0o700) do
          write_and_run(Path.join(directory, "source"), bytes, callback)
        end
      after
        File.rmdir(directory)
      end
    end
  end

  defp write_and_run(path, bytes, callback) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        try do
          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(file, bytes),
               :ok <- File.close(file) do
            callback.(path)
          end
        after
          File.close(file)
          File.rm(path)
        end

      {:error, _} = error ->
        error
    end
  end

  defp create_directory(0), do: {:error, :analyzer_scratch_unavailable}

  defp create_directory(attempts) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    directory = Path.join(System.tmp_dir!(), "ash-storage-analyzer-" <> suffix)

    case File.mkdir(directory) do
      :ok -> {:ok, directory}
      {:error, :eexist} -> create_directory(attempts - 1)
      {:error, _} = error -> error
    end
  end
end
