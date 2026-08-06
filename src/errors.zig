//! Errors returned by the binary (un)marshaling path. Mirrors `errors.zig`;
//! each sentinel maps to a Zig error so callers can match with
//! `catch error.InvalidIdentifier` etc.

pub const Error = error{
    InvalidIdentifier,
    InvalidSize,
    TablesMismatch,
};

pub const invalid_identifier_msg = "crc32: invalid hash state identifier";
pub const invalid_size_msg = "crc32: invalid hash state size";
pub const tables_mismatch_msg = "crc32: tables do not match";
