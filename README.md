# cropdetect-filters

`cropdetect_vulkan` and `cropdetect_cuda`, Vulkan and CUDA ports of FFmpeg's
`cropdetect` filter, as patches for FFmpeg, and an mpv script that uses them to
crop black bars during playback.

## cropdetect_vulkan

Auto-detect the crop size on Vulkan frames.

It calculates the necessary cropping parameters and prints the recommended
parameters via the logging system. The detected dimensions correspond to the
non-black area of the input video. The frames are passed on unchanged.

### Compared with cropdetect

- The metadata keys (`lavfi.cropdetect.x1`, `x2`, `y1`, `y2`, `w`, `h`, `x`,
  `y`, `limit`), the log line and the values are those of `cropdetect`.
- The frames stay on the GPU. A compute shader sums the luma plane per row
  and per column, and only these sums are read back.
- Only the `black` mode is implemented. The options `mode`, `mv_threshold`,
  `low` and `high` do not exist.
- FFmpeg's timeline editing (`enable`) is not supported.

### Supported input

- Vulkan hardware frames only. Other frames have to be uploaded first, with
  `hwupload` in FFmpeg or `format=fmt=vulkan` in mpv.
- Planar and semi-planar YUV formats with 8 to 16 bits, such as `nv12`,
  `p010`, `p012`, `p016` and `yuv420p10`.
- RGB, XYZ, packed and floating-point formats are rejected.

As with the other Vulkan filters, a hardware device has to be initialized and
passed to the filter graph; see "Vulkan Video Filters" in the FFmpeg filters
documentation.

It has been tested on Windows with an NVIDIA GPU.

### Options

It accepts the following parameters:

- `limit`

  Set higher black value threshold, which can be optionally specified from
  nothing (0) to everything (255 for 8-bit based formats). An intensity value
  greater to the set value is considered non-black. It defaults to 24. You can
  also specify a value between 0.0 and 1.0 which will be scaled depending on
  the bitdepth of the pixel format.

- `round`

  The value which the width/height should be divisible by. It defaults to 16.
  The offset is automatically adjusted to center the video. Use 2 to get only
  even dimensions (needed for 4:2:2 video). 16 is best when encoding to most
  video codecs.

- `skip`

  Set the number of initial frames for which evaluation is skipped. Default
  is 2. Range is 0 to INT_MAX.

- `reset_count`, `reset`

  Set the counter that determines after how many frames the filter will reset
  the previously detected largest video area and start over to detect the
  current optimal crop area. Default value is 0.

  This can be useful when channel logos distort the video area. 0 indicates
  'never reset', and returns the largest area encountered during playback.

- `max_outliers`

  Set the number of non-black lines that may be passed over while searching
  from an edge towards the picture. Default value is 0, which stops at the
  first non-black line.

### Examples

- Find the video area surrounded by black borders, decoding with Vulkan:

  ```
  .\ffmpeg.exe -init_hw_device vulkan -hwaccel vulkan -hwaccel_output_format vulkan -i file.mkv -vf cropdetect_vulkan,metadata=mode=print -f null -
  ```

- The same for frames decoded in software:

  ```
  .\ffmpeg.exe -init_hw_device vulkan=vk -filter_hw_device vk -i file.mkv -vf hwupload,cropdetect_vulkan,metadata=mode=print -f null -
  ```

### Commands

This filter supports the following commands:

- `limit`

  The command accepts the same syntax of the corresponding option. If the
  specified expression is not valid, it is kept at its current value.

## cropdetect_cuda

Auto-detect the crop size on CUDA frames, such as those decoded with nvdec.

It is the same filter as `cropdetect_vulkan` for CUDA: the metadata, the log
line, the options and the commands are those of `cropdetect_vulkan` above. A
CUDA kernel sums the luma plane per row and per column, and only these sums are
read back.

### Supported input

- CUDA hardware frames only. Other frames have to be uploaded first, with
  `hwupload_cuda` in FFmpeg.
- The same formats as `cropdetect_vulkan`, and also `yuv444p10msb` and
  `yuv444p12msb`, which nvdec outputs for 4:4:4 video.

The hardware device comes from the input frames, so no device has to be passed
to the filter graph.

### Examples

- Find the video area surrounded by black borders, decoding with nvdec:

  ```
  .\ffmpeg.exe -hwaccel cuda -hwaccel_output_format cuda -i file.mkv -vf cropdetect_cuda,metadata=mode=print -f null -
  ```

## Building

The patches are made against FFmpeg master, and either or both can be applied.
Apply each with the script next to it, which keeps working when FFmpeg changes
the lines around the ones that register the filter:

```
cmake -DSOURCE_DIR=<ffmpeg> -P patch/ffmpeg-add-cropdetect_vulkan-filter.cmake
cmake -DSOURCE_DIR=<ffmpeg> -P patch/ffmpeg-add-cropdetect_cuda-filter.cmake
```

Then configure FFmpeg with `--enable-gpl` and:

- for `cropdetect_vulkan`, `--enable-vulkan`, with a SPIR-V compiler (`glslc`,
  `glslang` or `glslangValidator`) available at build time;
- for `cropdetect_cuda`, `--enable-cuda-llvm`, with clang and the
  [nv-codec-headers](https://github.com/FFmpeg/nv-codec-headers) available at
  build time. `--enable-cuda-nvcc` works too, but needs `--enable-nonfree`,
  which makes the binaries unredistributable.

The CUDA patch also defines `__shared__` in `compat/cuda/cuda_runtime.h`, which
the clang build of the kernels needs, as no kernel in FFmpeg used shared memory
before.

Patched binaries are at [sohnyj/mpv-winbuild](https://github.com/sohnyj/mpv-winbuild).

## mpv script

`script/toggle_autocrop.lua` inserts `cropdetect_vulkan` or `cropdetect_cuda`
and applies the detected area through `video-crop`.

It applies a dynamic crop that follows aspect ratio changes during playback,
such as those of IMAX films.

### Usage

`mpv.conf`:

```
gpu-context=winvk # or waylandvk or x11vk; only winvk is tested
gpu-api=vulkan
vo=gpu-next
hwdec=vulkan # hwdec=nvdec or hwdec=vulkan,nvdec
```

- `gpu-api=vulkan` is required.
- With `hwdec=vulkan`, which uses `cropdetect_vulkan`, or `hwdec=nvdec`, which
  uses `cropdetect_cuda`, **the frames are read on the GPU without being
  copied**, and no copy-back decoder is needed.
- With a `*-copy` decoder or the software decoder (`no`), they are uploaded to
  Vulkan first.
- Other hardware decoders, such as `d3d11va` or `vaapi`, are not supported.

`input.conf`:

```
KEY script-message toggle_autocrop
```

`menu.conf`:

```
Autocrop	script-message toggle_autocrop	checked=p["user-data/filter/autocrop"]
```

`script/toggle_autocrop.conf` is an example for `script-opts`.

To print the detected area without the script:

```
.\mpv.com --vo=gpu-next --gpu-api=vulkan --hwdec=vulkan --vf=lavfi=[cropdetect_vulkan] -v file.mkv
```
