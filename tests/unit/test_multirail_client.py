from __future__ import annotations

import ctypes
from types import SimpleNamespace

import pytest

from contextstore.storage.multirail_client import MultiRailError, MultiRailReader


def _lookup(generation: int) -> SimpleNamespace:
    key = SimpleNamespace(namespace="ns", object_key="key")
    descriptor = SimpleNamespace(
        key=key,
        object_handle="handle",
        object_generation=generation,
        content_etag=f"etag-{generation}",
        layout_version=1,
        size=8,
        is_striped=False,
        stripe_count=1,
        chunk_size=8,
    )
    chunk = SimpleNamespace(
        stripe_index=0,
        rdma_endpoint="127.0.0.1:50053",
        offset=0,
        length=8,
        checksum="",
    )
    return SimpleNamespace(
        descriptor=descriptor,
        placement=SimpleNamespace(chunks=[chunk]),
    )


class _FakeLibrary:
    def cs_mr_read(self, _handle, _descriptor, _chunks, _count, buffer, *_rest) -> int:
        ctypes.memset(buffer, 0x42, 8)
        return 8


class TestMultiRailReader:
    def test_verified_read_publishes_complete_bytes(self) -> None:
        reader = MultiRailReader.__new__(MultiRailReader)
        reader._lib = _FakeLibrary()
        reader._handle = 1
        destination = ctypes.create_string_buffer(b"AAAAAAAA", 8)
        client = SimpleNamespace(lookup_object_with_placement=lambda _key: _lookup(1))

        assert reader.read_into(destination, _lookup(1), verify_with=client) == 8
        assert destination.raw == b"BBBBBBBB"

    def test_version_change_keeps_caller_buffer_unchanged(self) -> None:
        reader = MultiRailReader.__new__(MultiRailReader)
        reader._lib = _FakeLibrary()
        reader._handle = 1
        destination = ctypes.create_string_buffer(b"AAAAAAAA", 8)
        client = SimpleNamespace(lookup_object_with_placement=lambda _key: _lookup(2))

        with pytest.raises(MultiRailError, match="version"):
            reader.read_into(destination, _lookup(1), verify_with=client)

        assert destination.raw == b"AAAAAAAA"
