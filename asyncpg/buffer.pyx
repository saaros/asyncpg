from cpython cimport Py_buffer
from libc.string cimport memcpy


DEF _BUFFER_INITIAL_SIZE = 256
DEF _BUFFER_MAX_GROW = 65536
DEF _BUFFER_FREELIST_SIZE = 256


class BufferError(Exception):
    pass


@cython.no_gc_clear
@cython.freelist(_BUFFER_FREELIST_SIZE)
cdef class WriteBuffer:
    cdef:
        char *_buf

        # Allocated size
        int _size

        # Length of data in the buffer
        int _length

        # Number of memoryviews attached to the buffer
        int _view_count

    def __cinit__(self):
        self._buf = <char*>PyMem_Malloc(sizeof(char) * _BUFFER_INITIAL_SIZE)
        if self._buf is NULL:
            raise MemoryError()
        self._size = _BUFFER_INITIAL_SIZE
        self._length = 0

    def __dealloc__(self):
        if self._buf is not NULL:
            PyMem_Free(self._buf)
            self._buf = NULL
            self._size = 0

        if self._view_count:
            raise RuntimeError(
                'Deallocating buffer with attached memoryviews')

    def __getbuffer__(self, Py_buffer *buffer, int flags):
        self._view_count += 1

        PyBuffer_FillInfo(
            buffer, self, self._buf, self._length,
            1,  # read-only
            flags)

    def __releasebuffer__(self, Py_buffer *buffer):
        self._view_count -= 1

    cdef inline len(self):
        return self._length

    cdef inline _ensure_alloced(self, int extra_length):
        cdef:
            int new_size = extra_length + self._length
            char *new_buf

        if new_size <= self._size:
            return

        if new_size < _BUFFER_MAX_GROW:
            new_size = _BUFFER_MAX_GROW
        # TODO else: pre-alloc even more

        new_buf = <char*>PyMem_Realloc(<void*>self._buf, new_size)
        if new_buf is NULL:
            PyMem_Free(self._buf)
            self._buf = NULL
            self._size = 0
            self._length = 0
            raise MemoryError()
        self._buf = new_buf
        self._size = new_size

    cdef write_buffer(self, WriteBuffer buf):
        if not buf._length:
            return

        self._ensure_alloced(buf._length)
        memcpy(self._buf + self._length,
               <void*>buf._buf,
               buf._length)
        self._length += buf._length

    cdef write_byte(self, char b):
        self._ensure_alloced(1)
        self._length += 1
        self._buf[self._length] = b

    cdef write_cstr(self, bytes string):
        cdef int slen = len(string) + 1
        self._ensure_alloced(slen)
        memcpy(self._buf + self._length,
               <void*>PyBytes_AsString(string),
               slen)
        self._length += slen

    cdef write_int16(self, int i):
        self._ensure_alloced(2)
        self._buf[self._length] = (i >> 8) & 0xFF
        self._buf[self._length + 1] = i & 0xFF
        self._length += 2

    cdef write_int32(self, int i):
        self._ensure_alloced(4)
        self._buf[self._length]     = (i >> 24) & 0xFF
        self._buf[self._length + 1] = (i >> 16) & 0xFF
        self._buf[self._length + 2] = (i >> 8) & 0xFF
        self._buf[self._length + 3] = i & 0xFF
        self._length += 4


@cython.no_gc_clear
@cython.freelist(_BUFFER_FREELIST_SIZE)
cdef class ReadBuffer:
    cdef:
        # A deque of buffers (bytes objects)
        object _bufs

        # A pointer to the first buffer in `_bufs`
        object _buf0

        # Number of buffers in `_bufs`
        int _bufs_len

        # A read position in the first buffer in `_bufs`
        int _pos0

        # Length of the first buffer in `_bufs`
        int _len0

        # A total number of buffered bytes in ReadBuffer
        int _length

        char _current_message_type
        int _current_message_len
        int _current_message_len_unread
        bint _current_message_ready

    def __cinit__(self):
        self._bufs = collections.deque()
        self._bufs_len = 0
        self._buf0 = None
        self._pos0 = 0
        self._len0 = 0
        self._length = 0

        self._current_message_type = 0
        self._current_message_len = 0
        self._current_message_len_unread = 0
        self._current_message_ready = 0

    cdef feed_data(self, bytes data):
        cdef int dlen = len(data)

        if dlen == 0:
            # EOF?
            return

        self._bufs.append(data)
        self._length += dlen

        if self._bufs_len == 0:
            # First buffer
            self._len0 = dlen
            self._buf0 = data

        self._bufs_len += 1

    cdef inline _ensure_first_buf(self):
        if self._len0 == 0:
            raise BufferError('empty first buffer')

        if self._pos0 == self._len0:
            # The first buffer is fully read, discard it
            self._bufs.popleft()
            self._bufs_len -= 1

            # Shouldn't fail, since we've checked that `_length >= 1`
            # in the beginning of this method.
            self._buf0 = self._bufs[0]

            self._pos0 = 0
            self._len0 = len(self._buf0)

            IF DEBUG:
                if self._len0 < 1:
                    raise RuntimeError(
                        'debug: second buffer of ReadBuffer is empty')

    cdef inline read_byte(self):
        if self._length < 1:
            raise BufferError('not enough data to read one byte')

        if self._current_message_ready:
            self._current_message_len_unread -= 1
            if self._current_message_len_unread < 0:
                raise BufferError('buffer overread')

        IF DEBUG:
            if not self._buf0:
                raise RuntimeError(
                    'debug: first buffer of ReadBuffer is empty')

        self._ensure_first_buf()

        byte = self._buf0[self._pos0]
        self._pos0 += 1
        self._length -= 1
        return byte

    cdef inline read_bytes(self, int nbytes):
        cdef:
            object result
            int nread

        if nbytes == 1:
            return self.read_byte()

        if nbytes > self._length:
            raise BufferError(
                'not enough data to read {} bytes'.format(nbytes))

        if self._current_message_ready:
            self._current_message_len_unread -= nbytes
            if self._current_message_len_unread < 0:
                raise BufferError('buffer overread')

        self._ensure_first_buf()

        if self._pos0 + nbytes <= self._len0:
            result = memoryview(self._buf0)
            result = result[self._pos0 : self._pos0 + nbytes]
            self._pos0 += nbytes
            self._length -= nbytes
            return result

        result = bytearray()
        while True:
            if self._pos0 + nbytes > self._len0:
                result.extend(self._buf0[self._pos0:])
                nread = self._len0 - self._pos0
                self._pos0 = self._len0
                self._length -= nread
                nbytes -= nread
                self._ensure_first_buf()

            else:
                result.extend(self._buf0[self._pos0:self._pos0 + nbytes])
                self._pos0 += nbytes
                self._length -= nbytes
                return result

    cdef inline read_int32(self):
        cdef:
            object buf
            int i

        buf = self.read_bytes(4)
        i = (<int>buf[0]) << 24
        i |= (<int>buf[1]) << 16
        i |= (<int>buf[2]) << 8
        i |= (<int>buf[3])
        return i

    cdef inline read_int16(self):
        cdef:
            object buf
            int i

        buf = self.read_bytes(4)
        i = (<int>buf[0]) << 8
        i |= (<int>buf[1])
        return i

    cdef inline read_cstr(self):
        if not self._current_message_ready:
            raise BufferError(
                'read_cstr only works when the message guaranteed '
                'to be in the buffer')

        cdef:
            int pos
            int nread
            bytes result = b''

        self._ensure_first_buf()
        while True:
            pos = self._buf0.find(b'\x00', self._pos0)
            if pos >= 0:
                result += self._buf0[self._pos0 : pos]
                nread = pos - self._pos0 + 1
                self._pos0 = pos + 1
                self._length -= nread

                self._current_message_len_unread -= nread
                if self._current_message_len_unread < 0:
                    raise BufferError('buffer overread')

                return result

            else:
                result += self._buf0[self._pos0:]
                nread = self._len0 - self._pos0
                self._pos0 = self._len0
                self._length -= nread

                self._current_message_len_unread -= nread
                if self._current_message_len_unread < 0:
                    raise BufferError('buffer overread')

                self._ensure_first_buf()

    cdef has_message(self):
        if self._current_message_ready:
            return True

        if self._length < 5:
            # 5 == 1 (message type byte) + 4 (message length) --
            # we need at least that.
            return False

        if self._current_message_type == 0:
            self._current_message_type = self.read_byte()

        if self._current_message_len == 0:
            self._current_message_len = self.read_int32()
            self._current_message_len_unread = self._current_message_len - 4

        if self._length < self._current_message_len:
            return False

        self._current_message_ready = 1
        return True

    cdef discard_message(self):
        if not self._current_message_ready:
            raise BufferError('no message to discard')

        if self._current_message_len_unread:
            discarded = self.read_bytes(self._current_message_len_unread)
            IF DEBUG:
                print('!!! discarding message {!r} unread data: {!r}'.format(
                    chr(self._current_message_type), bytes(discarded)))

        self._current_message_type = 0
        self._current_message_len = 0
        self._current_message_ready = 0
        self._current_message_len_unread = 0

    cdef get_message_type(self):
        return self._current_message_type

    cdef get_message_length(self):
        return self._current_message_len