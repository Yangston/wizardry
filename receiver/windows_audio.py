"""Small stdlib-only Core Audio adapter. Each call releases all COM interfaces."""
import ctypes
import platform
import uuid
from contextlib import contextmanager


class GUID(ctypes.Structure):
    _fields_ = [("bytes", ctypes.c_ubyte * 16)]

    def __init__(self, value):
        super().__init__()
        self.bytes[:] = uuid.UUID(value).bytes_le


def _call(pointer, index, arguments, *values):
    table = ctypes.cast(pointer, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
    method = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_void_p, *arguments)(table[index])
    result = method(pointer, *values)
    if result < 0:
        raise OSError(f"Core Audio HRESULT 0x{result & 0xffffffff:08x}")


@contextmanager
def _endpoint():
    if platform.system() != "Windows":
        raise RuntimeError("Core Audio requires Windows")
    ole = ctypes.OleDLL("ole32")
    ole.CoInitializeEx.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    ole.CoInitializeEx.restype = ctypes.c_long
    result = ole.CoInitializeEx(None, 2)
    if result < 0:
        raise OSError("Cannot initialize Core Audio COM apartment")
    pointers = []
    try:
        enumerator = ctypes.c_void_p()
        cls = GUID("bcde0395-e52f-467c-8e3d-c4579291692e")
        iid = GUID("a95664d2-9614-4f35-a746-de8db63617e6")
        ole.CoCreateInstance.argtypes = [ctypes.POINTER(GUID), ctypes.c_void_p, ctypes.c_ulong,
                                        ctypes.POINTER(GUID), ctypes.POINTER(ctypes.c_void_p)]
        ole.CoCreateInstance.restype = ctypes.c_long
        result = ole.CoCreateInstance(ctypes.byref(cls), None, 23, ctypes.byref(iid), ctypes.byref(enumerator))
        if result < 0:
            raise OSError("Cannot open Windows audio endpoint enumerator")
        pointers.append(enumerator)
        device = ctypes.c_void_p()
        _call(enumerator, 4, [ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)], 0, 1, ctypes.byref(device))
        pointers.append(device)
        name = ctypes.c_void_p()
        _call(device, 5, [ctypes.POINTER(ctypes.c_void_p)], ctypes.byref(name))
        try:
            device_id = ctypes.wstring_at(name)
        finally:
            ole.CoTaskMemFree.argtypes = [ctypes.c_void_p]
            ole.CoTaskMemFree(name)
        volume = ctypes.c_void_p()
        iid = GUID("5cdf2c82-841e-4546-9722-0cf74078229a")
        _call(device, 3, [ctypes.POINTER(GUID), ctypes.c_ulong, ctypes.c_void_p,
                          ctypes.POINTER(ctypes.c_void_p)], ctypes.byref(iid), 23, None, ctypes.byref(volume))
        pointers.append(volume)
        yield volume, device_id
    finally:
        for pointer in reversed(pointers):
            _call(pointer, 2, [])
        ole.CoUninitialize()


class WindowsAudio:
    def read(self):
        with _endpoint() as (endpoint, device_id):
            value = ctypes.c_float()
            _call(endpoint, 9, [ctypes.POINTER(ctypes.c_float)], ctypes.byref(value))
            return float(value.value), device_id

    def set(self, target, expected_device):
        with _endpoint() as (endpoint, device_id):
            if device_id != expected_device:
                raise RuntimeError("Default audio device changed; activate again")
            _call(endpoint, 7, [ctypes.c_float, ctypes.c_void_p], target, None)
            value = ctypes.c_float()
            _call(endpoint, 9, [ctypes.POINTER(ctypes.c_float)], ctypes.byref(value))
            return float(value.value)
