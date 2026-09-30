/// System SDK 错误集合
pub const SdkError = error{
    NotSupported,
    Unavailable,
    InvalidState,
    WrongThread,
    BufferTooSmall,
    Timeout,
    BackendFailure,
    OutOfMemory,
};
