cimport libav as lib

from av.audio.format cimport AudioFormat, get_audio_format
from av.audio.layout cimport AudioLayout, get_audio_layout
from av.audio.frame cimport AudioFrame, alloc_audio_frame
from av.frame cimport Frame
from av.packet cimport Packet
from av.utils cimport err_check


cdef class AudioCodecContext(CodecContext):


    cdef _init(self, lib.AVCodecContext *ptr, lib.AVCodec *codec):
        CodecContext._init(self, ptr, codec)

        # Sometimes there isn't a layout set, but there are a number of
        # channels. Assume it is the default layout.
        # TODO: Put this behind `not bare_metal`.
        # TODO: Do this more efficiently.
        if self.ptr.channels and not self.ptr.channel_layout:
            self.ptr.channel_layout = get_audio_layout(self.ptr.channels, 0).layout

    cdef _prepare_frames_for_encode(self, Frame input_frame):

        cdef AudioFrame frame = input_frame

        # Resample. A None frame will flush the resampler, and then the fifo (if used).
        if not self.resampler:
            self.resampler = AudioResampler(
                self.format,
                self.layout,
                self.ptr.sample_rate
            )
        frame = self.resampler.resample(frame)
        
        cdef bint is_flushing = input_frame is None
        cdef bint use_fifo = not (self.ptr.codec.capabilities & lib.CODEC_CAP_VARIABLE_FRAME_SIZE)

        frames = []

        if use_fifo:

            if not self.fifo:
                self.fifo = AudioFifo()
            if frame:
                self.fifo.write(frame)

            # Pull partial frames if we were requested to flush (via a None frame).
            while (self.fifo.samples >= self.ptr.frame_size) or (self.fifo.samples and is_flushing):
                frame = self.fifo.read(self.ptr.frame_size, partial=is_flushing)
                if frame or not frames:
                    frames.append(frame)
                else:
                    break

        else:
            frames.append(frame)

        return frames

    cdef _encode(self, Frame frame):
        """Encodes a frame of audio, returns a packet if one is ready.
        The output packet does not necessarily contain data for the most recent frame, 
        as encoders can delay, split, and combine input frames internally as needed.
        If called with with no args it will flush out the encoder and return the buffered
        packets until there are none left, at which it will return None.
        """

        cdef Packet packet = Packet()
        cdef int got_packet = 0

        err_check(lib.avcodec_encode_audio2(
            self.ptr,
            &packet.struct,
            frame.ptr if frame is not None else NULL,
            &got_packet,
        ))

        if got_packet:
            return packet
        
    cdef Frame _alloc_next_frame(self):
        return alloc_audio_frame()

    cdef _decode(self, lib.AVPacket *packet, int *data_consumed):

        if not self.next_frame:
            self.next_frame = alloc_audio_frame()

        cdef int completed_frame = 0
        data_consumed[0] = err_check(lib.avcodec_decode_audio4(self.ptr, self.next_frame.ptr, &completed_frame, packet))
        if not completed_frame:
            return
        
        cdef AudioFrame frame = self.next_frame
        self.next_frame = None
        
        frame._init_properties()

        return frame

    cdef _setup_decoded_frame(self, Frame frame):
        CodecContext._setup_decoded_frame(self, frame)
        cdef AudioFrame aframe = frame
        aframe._init_properties()

    property frame_size:
        """Number of samples per channel in an audio frame."""
        def __get__(self): return self.ptr.frame_size
    
    property sample_rate:
        """Number samples of per second."""
        def __get__(self):
            return self.ptr.sample_rate
        def __set__(self, int value):
            self.ptr.sample_rate = value

    # TODO: Deprecate.
    property rate:
        """Number samples of per second."""
        def __get__(self):
            return self.ptr.sample_rate
        def __set__(self, int value):
            self.ptr.sample_rate = value

    # TODO: Integrate into AudioLayout.
    property channels:
        def __get__(self):
            return self.ptr.channels
        def __set__(self, value):
            self.ptr.channels = value
            self.ptr.channel_layout = lib.av_get_default_channel_layout(value)
    property channel_layout:
        def __get__(self):
            return self.ptr.channel_layout

    property layout:
        def __get__(self):
            return get_audio_layout(self.ptr.channels, self.ptr.channel_layout)
        def __set__(self, value):
            cdef AudioLayout layout = AudioLayout(value)
            self.ptr.channel_layout = layout.layout
            self.ptr.channels = layout.nb_channels

    property format:
        def __get__(self):
            return get_audio_format(self.ptr.sample_fmt)
        def __set__(self, value):
            cdef AudioFormat format = AudioFormat(value)
            self.ptr.sample_fmt = format.sample_fmt

    
