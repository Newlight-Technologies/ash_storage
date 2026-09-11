# Analyzers

Analyzers extract metadata from uploaded files — image dimensions, line counts, file hashes, etc. Results are stored on the blob's `analyzers` map and can optionally be written back to attributes on the parent record.

## Defining an analyzer

Implement the `AshStorage.Analyzer` behaviour:

```elixir
defmodule MyApp.ImageDimensions do
  @behaviour AshStorage.Analyzer

  @impl true
  def accept?("image/png"), do: true
  def accept?("image/jpeg"), do: true
  def accept?(_), do: false

  @impl true
  def analyze(path, _opts) do
    # path is a local file path to the uploaded content
    {:ok, %{"width" => 1920, "height" => 1080}}
  end
end
```

- `accept?/1` receives the blob's content type. Return `false` to skip analysis for that file.
- `analyze/2` receives the file path and any opts from the DSL. Return `{:ok, metadata_map}` or `{:error, reason}`.

## Adding analyzers to attachments

Declare analyzers inside `has_one_attached` or `has_many_attached` blocks:

```elixir
storage do
  has_one_attached :cover_image do
    analyzer MyApp.ImageDimensions
    analyzer {MyApp.FileInfo, include_exif: true}
  end
end
```

The `{Module, opts}` tuple form passes `opts` as the second argument to `analyze/2`.

By default, analyzers run eagerly — synchronously during the attach operation, before the response is returned. The file data is still in memory from the upload, so no download round-trip is needed.

When AshStorage creates an analyzer source file (for uploaded bytes, streamed
file values without a path, or background downloads), it uses a private `0700`
temporary directory and a `0600` file. Its owned source file and directory are
removed after the analyzer returns or raises. Existing caller-owned file paths
are borrowed without changing permissions or deleting them; callers remain
responsible for securing those paths. Analysis is not a pre-upload malware gate.

Private scratch setup failures return the typed, retryable
`analyzer_scratch_unavailable` failure. Background analysis records that failure
through its normal completion action; eager attachment propagates the setup
failure rather than proceeding without analysis. Normal callback return and
exception cleanup is covered, but process termination can leave private scratch
files behind; host-level cleanup remains an operational responsibility.

## Reading analyzer results

Analyzer results are stored across two blob fields:

- `blob.analyzers` tracks the status of each analyzer
- `blob.metadata` holds the merged result data from all analyzers

```elixir
post = Ash.load!(post, cover_image: :blob)

post.cover_image.blob.analyzers
#=> %{
#   "MyApp.ImageDimensions" => %{"status" => "complete", "opts" => %{}}
# }

post.cover_image.blob.metadata
#=> %{"width" => 1920, "height" => 1080}
```

If multiple analyzers return overlapping keys, later results overwrite earlier ones in the metadata map.

### Failures and explicit retries

An analyzer returning `{:error, reason}` records `"status" => "error"` and a
`"failure"` map on its analyzer entry. Static atom reasons are retained as codes;
arbitrary strings, exceptions, and other terms become `"analyzer_failed"` so
document contents, scanner output, and local paths are not persisted as errors.
For a known transient condition, return a typed failure:

```elixir
{:error, %AshStorage.Analyzer.Failure{code: :scanner_unavailable, retryable?: true}}
```

This records `%{"code" => "scanner_unavailable", "retryable" => true}`. The flag
is evidence for the caller's recovery policy. Outside an AshOban worker,
`run_pending_analyzers` records failures without scheduling retries. An authorized caller can
explicitly invoke `AshStorage.Operations.run_analyzer/3` again for an errored
entry; success clears its failure and merges the new result metadata.
Returned storage download errors likewise persist `analyzer_download_failed`
with retryability enabled, without copying storage error details. Recovery still
requires the original object to be available and pass the service's checksum
verification before analysis can succeed.

When run by an AshOban trigger, transient failures remain pending while the
job has attempts remaining, and the action fails to request Oban's normal
retry/backoff. At the final attempt they become errored and clear scheduler
eligibility. Configure a finite `max_attempts` on the trigger. Successful and
terminally failed analyzers are not rerun on the next attempt. The action is
non-transactional and performs analysis after its action transaction so a job
error does not roll back already-recorded failure evidence. Do not wrap it in
an outer application transaction.

The operation returning `{:ok, blob}` means the analysis outcome was persisted,
not that the file passed analysis. Consumers must inspect the analyzer status
and their analyzer's verdict. Neither an error nor a completed malware analysis
alone proves a clean file. Applications must keep pre-upload malware admission
separate from this post-upload lifecycle.

## Writing results to parent attributes

Use `write_attributes` to map analyzer result keys to attributes on the parent record:

```elixir
storage do
  has_one_attached :cover_image do
    analyzer MyApp.ImageDimensions,
      write_attributes: [width: :image_width, height: :image_height]
  end
end

attributes do
  attribute :image_width, :integer, public?: true
  attribute :image_height, :integer, public?: true
end
```

When `ImageDimensions` returns `%{"width" => 1920, "height" => 1080}`, the values are written to `:image_width` and `:image_height` on the parent record as part of the same action — no extra update query.

For eager analyzers, this happens in a `before_action` hook via `force_change_attributes`. For oban analyzers, a separate update is performed when the background job completes.

Background result persistence groups blob completion and the configured parent
update in an Ash transaction. A returned lookup/update error is not ignored:
the transaction rolls back and the blob records `analyzer_result_write_failed`
for recovery. Scanning happens before this database transaction. Atomicity
requires transactional resources in the same database; this is not a distributed
transaction guarantee across storage services or independent databases.

## Background analysis with AshOban

For expensive analysis (video processing, large file scanning), run analyzers in the background:

```elixir
has_one_attached :video do
  analyzer MyApp.VideoDuration, analyze: :oban
end
```

This requires AshOban to be configured on your blob resource:

```elixir
defmodule MyApp.StorageBlob do
  use Ash.Resource,
    extensions: [AshStorage.BlobResource, AshOban]

  blob do
  end

  oban do
    triggers do
      trigger :run_pending_analyzers do
        action :run_pending_analyzers
        on_error :fail_pending_analyzers
        on_error_fails_job? true
        read_action :read
        where expr(pending_analyzers == true)
        scheduler_cron("* * * * *")
        max_attempts(3)
      end
    end
  end

  attributes do
    uuid_primary_key :id
  end
end
```

The `where` clause ensures only blobs with pending analyzers are picked up. When the trigger fires, the `:run_pending_analyzers` action downloads the file from storage and runs each pending analyzer.

The generated `:fail_pending_analyzers` action is the exhaustion handler for
exceptions that prevented a normal analyzer outcome from being recorded. It
marks unfinished entries as errored, retains completed entries, and records
`analyzer_job_exhausted` without persisting raw exception contents. Configure
policies for this action alongside the run and completion actions. Existing
triggers must explicitly add `on_error`; adding the library action alone does
not change their configuration. Job timeouts and process-loss recovery still
depend on the host application's Oban configuration.

If you use `analyze: :oban` without this trigger configured, a compile-time verifier will raise an error telling you what to add.

## Mixing eager and oban analyzers

You can combine both on the same attachment:

```elixir
has_one_attached :photo do
  analyzer MyApp.FileInfo                           # runs immediately
  analyzer MyApp.ImageDimensions, analyze: :oban    # runs in background
end
```

The eager analyzer runs during attach. The oban analyzer is queued and runs when Oban picks it up.
