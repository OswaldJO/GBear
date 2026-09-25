// Moonlight's iOS libavcodec.a includes av1dec.o but not av1_parse.o (ff_av1_framerate).
// Match FFmpeg's av1_parse.c implementation so AV1 decode links in Debug builds.

#include <libavutil/mathematics.h>
#include <libavutil/rational.h>

#include <limits.h>
#include <stdint.h>

AVRational ff_av1_framerate(int64_t ticks_per_frame, int64_t units_per_tick, int64_t time_scale)
{
    AVRational fr = {0, 1};

    if (ticks_per_frame && units_per_tick && time_scale &&
        ticks_per_frame < INT_MAX / units_per_tick) {
        av_reduce(&fr.den, &fr.num, units_per_tick * ticks_per_frame, time_scale, INT_MAX);
    }

    return fr;
}
