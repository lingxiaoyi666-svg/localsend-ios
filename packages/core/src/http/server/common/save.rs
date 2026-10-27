use crate::crypto;
use bytes::Bytes;
use http_body_util::BodyExt;
use hyper::body::Incoming;
use hyper::Request;
use std::future::Future;
use std::path::PathBuf;
use tokio::sync::{mpsc, oneshot};

/// Channel capacity for file upload chunks (provides backpressure).
const UPLOAD_CHANNEL_CAPACITY: usize = 16;

/// Size of the write buffer that coalesces incoming body chunks (typically one
/// TLS record, ~16 KiB) into larger file writes.
const WRITE_BUFFER_SIZE: usize = 512 * 1024;

/// Where the content of an uploaded file should go, decided by the application.
#[derive(Debug)]
pub enum FileUploadTarget {
    /// The application consumes the binary chunks itself.
    ///
    /// The server forwards chunks into `binary_tx` and closes it at end of file.
    /// The application should compare the number of received bytes with `file.size`
    /// and report the result on the sender side of `result_rx` which determines
    /// the HTTP response (200 on `Ok`, 500 on `Err` or when the sender is dropped).
    ///
    /// Note: the checksum is only verified after the application reported its
    /// result, so a checksum mismatch is not observable by the application here
    /// (unlike [FileUploadTarget::Path] and [FileUploadTarget::Fd]).
    Stream {
        /// Channel the server sends the binary chunks of the file into.
        binary_tx: mpsc::Sender<Bytes>,

        /// Channel on which the application reports whether the file was
        /// processed successfully.
        result_rx: oneshot::Receiver<Result<(), String>>,
    },

    /// The server writes the file to this path (created or truncated)
    /// and reports the result on `result_tx`.
    ///
    /// Timestamps provided in the sender's file metadata are applied to the
    /// written file, so the application does not need to set them itself.
    Path {
        /// The path to write the file to.
        path: PathBuf,

        /// Channel on which the server reports whether the file was saved
        /// successfully, including the checksum verification if one was given.
        result_tx: oneshot::Sender<Result<(), String>>,

        /// Optional channel on which the server reports the number of bytes
        /// written so far. Events are dropped when the channel is full.
        progress_tx: Option<mpsc::Sender<u64>>,
    },

    /// The server writes the file to this raw file descriptor (Android only)
    /// and reports the result on `result_tx`.
    ///
    /// Timestamps provided in the sender's file metadata are applied through
    /// the descriptor, which also covers SAF documents that have no path.
    #[cfg(target_os = "android")]
    Fd {
        /// The raw file descriptor to write the file to.
        /// Ownership is transferred; the descriptor is closed after writing.
        fd: std::os::fd::RawFd,

        /// Channel on which the server reports whether the file was saved
        /// successfully, including the checksum verification if one was given.
        result_tx: oneshot::Sender<Result<(), String>>,

        /// Optional channel on which the server reports the number of bytes
        /// written so far. Events are dropped when the channel is full.
        progress_tx: Option<mpsc::Sender<u64>>,
    },
}

/// The sender-provided timestamps of an uploaded file, applied to the written
/// file for [FileUploadTarget::Path] and [FileUploadTarget::Fd].
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct FileTimestamps {
    pub modified: Option<std::time::SystemTime>,
    pub accessed: Option<std::time::SystemTime>,
}

impl FileTimestamps {
    fn is_empty(&self) -> bool {
        self.modified.is_none() && self.accessed.is_none()
    }
}

/// Outcome of receiving an uploaded file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SaveResult {
    /// The file has been received and, if a checksum was given, it matched.
    Success,

    /// The body could not be read or the target failed to process it.
    Failed,

    /// The received bytes do not match the expected SHA-256 checksum.
    HashMismatch,

    /// A requested resume offset could not be applied to the target.
    ///
    /// Nothing was written and the file is reset to a pending state so the
    /// sender can retry the same file from the beginning. Only resumable
    /// targets (paths) qualify; descriptor and stream targets have no way to
    /// inspect the content the receiver already holds.
    ResumeRejected,
}

/// Forwards the body of `req` to `target`.
///
/// `resume_offset` continues an interrupted transfer: the first `offset` bytes
/// of the file are already on disk and are not sent again. Only
/// [FileUploadTarget::Path] supports it (the partial file can be opened for
/// writing and read back for the checksum); for any other target the resume
/// request is answered with [SaveResult::ResumeRejected] and nothing is
/// written, so the sender can repeat the upload from the beginning.
pub(crate) async fn save_req_to_target(
    req: Request<Incoming>,
    target: FileUploadTarget,
    file_size: u64,
    expected_sha256: Option<&str>,
    timestamps: FileTimestamps,
    resume_offset: Option<u64>,
) -> SaveResult {
    use sha2::{Digest, Sha256};

    // A resume offset only means something for a path target. `0` is not a
    // resume at all: the file is written from the start, exactly like a normal
    // upload, which keeps the behavior for senders that always pass `offset=0`.
    let resume = match &target {
        FileUploadTarget::Path { .. } => resume_offset.filter(|offset| *offset > 0),
        _ => None,
    };

    // The already received prefix is not part of the body, but it is part of
    // the file, so it has to be hashed up front to verify the checksum. The
    // same read proves that the partial file still holds at least `offset`
    // bytes; if it does not, the offer is stale and the sender must start over.
    let mut hasher = expected_sha256.map(|_| Sha256::new());
    let prefix_error = match (resume, &target) {
        (Some(offset), FileUploadTarget::Path { path, .. }) => {
            read_prefix(hasher.as_mut(), path, offset).await.err()
        }
        _ => None,
    };

    // Resolve the target into a chunk sender and a result receiver.
    // For [FileUploadTarget::Path] and [FileUploadTarget::Fd], the application's
    // result channel is answered by this function once the complete outcome
    // (including the checksum verification) is known.
    let (binary_tx, result_rx, app_result_tx) = match target {
        FileUploadTarget::Stream {
            binary_tx,
            result_rx,
        } => (binary_tx, result_rx, None),
        FileUploadTarget::Path {
            path,
            result_tx,
            progress_tx,
        } => {
            if let Some(err) = prefix_error {
                // Nothing has been written: the partial file is left untouched
                // so a later attempt can still continue it.
                tracing::warn!("Rejecting resume of {}: {err}", path.display());
                let _ = result_tx.send(Err(err));
                return SaveResult::ResumeRejected;
            }
            let (binary_tx, result_rx) = spawn_file_writer(
                open_path(path, resume),
                file_size,
                progress_tx,
                timestamps,
                resume.unwrap_or(0),
            );
            (binary_tx, result_rx, Some(result_tx))
        }
        #[cfg(target_os = "android")]
        FileUploadTarget::Fd {
            fd,
            result_tx,
            progress_tx,
        } => {
            let (binary_tx, result_rx) = spawn_file_writer(
                async move {
                    use std::os::fd::FromRawFd;

                    // SAFETY: the descriptor is owned by this transfer; wrapping it in
                    // a File transfers that ownership so it is closed once writing finishes.
                    let std_file = unsafe { std::fs::File::from_raw_fd(fd) };
                    Ok(tokio::fs::File::from_std(std_file))
                },
                file_size,
                progress_tx,
                timestamps,
                0,
            );
            (binary_tx, result_rx, Some(result_tx))
        }
    };

    // Forward the request body to the target, hashing it on the way if
    // requested. The hasher already holds the prefix of a resumed transfer.
    let mut body = req.into_body();
    let mut stream_error = false;
    while let Some(frame) = body.frame().await {
        match frame {
            Ok(frame) => {
                let Ok(data) = frame.into_data() else {
                    continue; // ignore non-data frames (e.g. trailers)
                };
                if data.is_empty() {
                    continue;
                }
                if let Some(hasher) = &mut hasher {
                    hasher.update(&data);
                }
                if binary_tx.send(data).await.is_err() {
                    // The receiver is gone (dropped by the application or
                    // closed by the file writer after an error).
                    stream_error = true;
                    break;
                }
            }
            Err(err) => {
                tracing::warn!("Error reading upload body of file: {err:#}");
                stream_error = true;
                break;
            }
        }
    }

    // Signal end of file to the receiving side.
    drop(binary_tx);

    // Determine the outcome; `error` carries the reason for the application.
    let (result, error): (SaveResult, Option<String>) = 'outcome: {
        if stream_error {
            // The file writer (if any) fails with a size mismatch or its own
            // write error once the channel is closed; collect that reason.
            let error = match app_result_tx.is_some() {
                true => match result_rx.await {
                    Ok(Err(err)) => Some(err),
                    _ => None,
                },
                false => None,
            };
            break 'outcome (
                SaveResult::Failed,
                error.or(Some("Upload aborted".to_string())),
            );
        }

        match result_rx.await {
            Ok(Ok(())) => (),
            Ok(Err(err)) => {
                tracing::warn!("Failed to process file: {err}");
                break 'outcome (SaveResult::Failed, Some(err));
            }
            Err(_) => break 'outcome (SaveResult::Failed, Some("Upload aborted".to_string())),
        }

        if let (Some(hasher), Some(expected)) = (hasher, expected_sha256) {
            let actual = crypto::hash::to_hex(&hasher.finalize());
            if !actual.eq_ignore_ascii_case(expected) {
                tracing::warn!("Checksum mismatch: expected {expected}, got {actual}");
                break 'outcome (
                    SaveResult::HashMismatch,
                    Some("Checksum mismatch".to_string()),
                );
            }
        }

        (SaveResult::Success, None)
    };

    if let Some(app_result_tx) = app_result_tx {
        let _ = app_result_tx.send(match error {
            None => Ok(()),
            Some(err) => Err(err),
        });
    }

    result
}

/// Opens the file behind a [FileUploadTarget::Path] for writing.
///
/// Without a resume offset the file is created (or truncated), exactly like a
/// fresh upload. With one the existing partial file is opened without
/// truncation and positioned at the offset, so the remaining bytes land right
/// behind the content the receiver already holds.
fn open_path(
    path: PathBuf,
    resume: Option<u64>,
) -> impl Future<Output = Result<tokio::fs::File, String>> + Send + 'static {
    async move {
        match resume {
            None => tokio::fs::File::create(&path)
                .await
                .map_err(|e| format!("Failed to create {}: {e}", path.display())),
            Some(offset) => {
                use tokio::io::AsyncSeekExt;

                let mut file = tokio::fs::OpenOptions::new()
                    .write(true)
                    .open(&path)
                    .await
                    .map_err(|e| format!("Failed to resume {}: {e}", path.display()))?;
                file.seek(std::io::SeekFrom::Start(offset))
                    .await
                    .map_err(|e| format!("Failed to seek {} to {offset}: {e}", path.display()))?;
                Ok(file)
            }
        }
    }
}

/// Reads the first `offset` bytes of `path` and, if a hasher is given, feeds
/// them into it.
///
/// Used to verify the checksum of a resumed transfer, whose body only carries
/// the bytes after the offset, and to confirm that the partial file still holds
/// at least `offset` bytes.
async fn read_prefix(
    mut hasher: Option<&mut sha2::Sha256>,
    path: &std::path::Path,
    offset: u64,
) -> Result<(), String> {
    use sha2::Digest;
    use tokio::io::AsyncReadExt;

    let file = tokio::fs::File::open(path)
        .await
        .map_err(|e| format!("Failed to reopen {}: {e}", path.display()))?;
    let mut reader = file.take(offset);
    let mut buffer = vec![0u8; 64 * 1024];
    let mut read: u64 = 0;
    loop {
        let n = reader
            .read(&mut buffer)
            .await
            .map_err(|e| format!("Failed to read {}: {e}", path.display()))?;
        if n == 0 {
            break;
        }
        read += n as u64;
        if let Some(hasher) = hasher.as_mut() {
            hasher.update(&buffer[..n]);
        }
    }
    if read != offset {
        return Err(format!(
            "Partial file {} holds only {read} of {offset} bytes",
            path.display()
        ));
    }
    Ok(())
}

/// Spawns a task that writes incoming chunks to a file provided by `open`.
///
/// `append_from` is the number of bytes already on disk that the incoming
/// chunks are appended to (zero for a fresh upload).
///
/// Returns the sender for the binary chunks and a receiver for the final result.
fn spawn_file_writer(
    open: impl Future<Output = Result<tokio::fs::File, String>> + Send + 'static,
    expected_size: u64,
    progress_tx: Option<mpsc::Sender<u64>>,
    timestamps: FileTimestamps,
    append_from: u64,
) -> (mpsc::Sender<Bytes>, oneshot::Receiver<Result<(), String>>) {
    let (binary_tx, mut binary_rx) = mpsc::channel::<Bytes>(UPLOAD_CHANNEL_CAPACITY);
    let (internal_tx, internal_rx) = oneshot::channel::<Result<(), String>>();

    tokio::spawn(async move {
        let result = write_file_from_receiver(
            open,
            expected_size,
            append_from,
            &mut binary_rx,
            progress_tx,
            timestamps,
        )
        .await;
        // Unblock the request handler if it is still sending chunks.
        binary_rx.close();
        let _ = internal_tx.send(result);
    });

    (binary_tx, internal_rx)
}

/// Writes all chunks received on `rx` to the file provided by `open`.
///
/// The file is expected to hold `append_from` bytes already (a resumed
/// transfer); the chunks complete it to `expected_size`.
///
/// Fails if the resulting total does not match `expected_size` (e.g. the
/// sender disconnected mid-transfer).
///
/// The file is truncated to the written size, so that a target that pointed at
/// a longer, pre-existing file cannot keep a tail of the old content.
///
/// The sender-provided `timestamps` are applied to the completely written
/// file. This happens on the still-open handle: an Android file descriptor has
/// no path to address the file by afterwards.
async fn write_file_from_receiver(
    open: impl Future<Output = Result<tokio::fs::File, String>>,
    expected_size: u64,
    append_from: u64,
    rx: &mut mpsc::Receiver<Bytes>,
    progress_tx: Option<mpsc::Sender<u64>>,
    timestamps: FileTimestamps,
) -> Result<(), String> {
    use tokio::io::AsyncWriteExt;

    let mut file = tokio::io::BufWriter::with_capacity(WRITE_BUFFER_SIZE, open.await?);
    let mut written: u64 = 0;
    while let Some(chunk) = rx.recv().await {
        written += chunk.len() as u64;
        // Reported progress is the file total, not just the bytes of this
        // attempt, so a resumed transfer continues where the bar stopped.
        let total = append_from + written;
        if total > expected_size {
            return Err(format!(
                "Expected {expected_size} bytes, received at least {total}"
            ));
        }
        file.write_all(&chunk)
            .await
            .map_err(|e| format!("Failed to write file: {e}"))?;
        if let Some(progress_tx) = &progress_tx {
            // Progress is best-effort: drop the event when the consumer lags.
            let _ = progress_tx.try_send(total);
        }
    }
    file.flush()
        .await
        .map_err(|e| format!("Failed to flush file: {e}"))?;
    let file = file.into_inner();

    let total = append_from + written;
    if total != expected_size {
        return Err(format!(
            "Expected {expected_size} bytes, received {total}"
        ));
    }

    // Drops content beyond the file that was just written, in case the target
    // pointed at a longer, pre-existing file: opening truncates for paths and
    // for descriptors opened with the SAF "wt" mode, but a document provider is
    // free to ignore that mode. Retries of the same upload are covered by the
    // exact size check above either way.
    //
    // Best-effort: a provider may back the descriptor by something that cannot
    // be truncated (e.g. a pipe), which must not fail the completed transfer.
    if let Err(e) = file.set_len(total).await {
        tracing::warn!("Could not truncate file to {total} bytes: {e}");
    }

    // The timestamps are applied last because the writes and the truncation
    // above update the modification time themselves.
    //
    // Best-effort: the provider backing an Android file descriptor may not
    // support changing timestamps, which must not fail the completed transfer.
    if !timestamps.is_empty() {
        let mut times = std::fs::FileTimes::new();
        if let Some(modified) = timestamps.modified {
            times = times.set_modified(modified);
        }
        if let Some(accessed) = timestamps.accessed {
            times = times.set_accessed(accessed);
        }
        let file = file.into_std().await;
        // Also closes the file, off the async runtime like tokio::fs does.
        let result = tokio::task::spawn_blocking(move || file.set_times(times)).await;
        if let Ok(Err(e)) = result {
            tracing::warn!("Could not set file timestamps: {e}");
        }
    }

    Ok(())
}
