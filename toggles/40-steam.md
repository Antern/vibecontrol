# Steam Remote Play host: prerequisites

What `40-steam.toggle` toggles is only the `-pipewire` flag. Everything below
has to exist on the host as well, or Remote Play either fails outright or
silently falls back to something much worse. Verified on Fedora 44, KDE
Plasma on Wayland, AMD GPU.

## 1. Steam must run with `-pipewire`

Without it, capture fails on Wayland:

    Unable to capture video: k_ECaptureFailedReasonPipewireRequired

That is what the toggle is for. Do not patch it into the desktop entry --
that imposes the flag on every launch; the toggle exists so plain Steam stays
plain.

On the first `-pipewire` start the portal asks which monitor to share. Answer
it **at the machine**, not over the stream. The grant is persistent:

    CDesktopCapturePipeWire: Finished obtaining persistent permissions

## 2. 32-bit EGL

    sudo dnf install mesa-libEGL.i686 libglvnd-egl.i686

Steam's client is a 32-bit binary and a 32-bit process cannot load a 64-bit
library, so the usual `/usr/lib64` copy is invisible to it. Without this:

    CDesktopCapturePipeWire: Couldn't load libEGL.so.1

EGL is what lets the capture import the compositor's DMA-BUF on the GPU
instead of copying every frame through the CPU.

## 3. H.264 encoding -- the one that actually bites on Fedora

    sudo dnf install \
      https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
    sudo dnf install mesa-va-drivers-freeworld mesa-va-drivers-freeworld.i686

Fedora ships Mesa with H.264 and HEVC **encoding removed** for patent reasons;
AV1 is left in because it is royalty free. Remote Play uses H.264, so on a
stock install every GPU in the machine reports:

    h264_vaapi: No usable encoding profile found
    CGameStreamVideoStageVAAPI: Failed to open codec: Function not implemented

Steam then falls back to software x264 at `preset=superfast`, which is the
real cause of a soft, blurry picture. This is not a GPU-selection problem:
both an RX 9070 and a Ryzen iGPU failed identically before the swap and both
passed after it. Check before blaming hardware:

    ffmpeg -init_hw_device vaapi=va:/dev/dri/renderD128 -filter_hw_device va \
      -f lavfi -i color=c=black:s=640x480:r=30:d=0.2 \
      -vf "format=nv12,hwupload" -c:v h264_vaapi -f null -   # exit 0 = usable

The `.i686` build matters for the same reason as EGL: the encoder runs inside
the 32-bit client.

## 4. Firewall

The client's traffic has to be allowed on whichever interface it arrives
through. A `firewalld` zone can look permissive and still reject everything --
`nm-shared` has `target: ACCEPT` but also a catch-all `rule priority="32767"
reject`, so only its listed services get in.

    sudo firewall-cmd --zone=<zone> --add-service=steam-streaming
    sudo firewall-cmd --permanent --zone=<zone> --add-service=steam-streaming

Two commands rather than `--reload`, so live SSH sessions are not disturbed.
The default workstation zone usually already opens 1025-65535 and needs
nothing.

## 5. The client's resolution cap -- the non-obvious one

Steam sizes the encoder to the **client's output size**, not the video size.
macOS renders Retina at 2x, so a MacBook on a 2560x1440 monitor reports a
5120x2880 backing store and the host tries to open the encoder at 5120 wide:

    ffmpeg error: Hardware does not support encoding at size 5120x1088
                  (constraints: width 128-4096 height 128-4096)
    Failed encoders: 5/4  ->  Created encoder X264

AMD's H.264/HEVC encoders cap at 4096. One failed open condemns the whole
session to software x264 at `preset=superfast` -- a soft picture and a pegged
CPU -- even though it settles to 1920x1080 moments later and never retries.

Fix it on the client: **Steam -> Settings -> Remote Play -> Advanced Client
Options -> Limit resolution to 1440p**. Running the client windowed instead of
fullscreen has the same effect.

This is not visible as an error in the UI. The only symptom is loud fans and a
soft image, so check the log rather than guessing.

## 6. Client codec settings

The host encodes H.264, HEVC and AV1 in hardware; what to enable depends
entirely on what the client can *decode* in hardware.

| Client | HEVC | AV1 |
|---|---|---|
| Apple Silicon (M1 and later, incl. M1 Pro) | yes | **no** |
| M3 and later | yes | yes |

HEVC is worth enabling everywhere -- roughly 25-50% better quality at the same
bitrate than H.264. AV1 only on M3 or newer; on an M1 or M2 it decodes in
software and simply moves the thermal problem to the client, which on a
fanless Air is worse than leaving it off.

Low latency networking is appropriate on a direct link and was never
implicated in anything here.

## What success looks like

    Allowed Codecs: 5,4
    Created encoder VAAPI for codec 5
    >>> Capture method set to Desktop PipeWire RGB DMABUF + VAAPI HEVC
    >>> Capture resolution set to 2560x1440

`VAAPI` rather than `libx264` means hardware encoding took. `RGB DMABUF`
rather than `NV12` means frames are imported on the GPU instead of copied
through the CPU, which is what the 32-bit EGL package buys. Full desktop
resolution rather than a downscale to 1920x1080 is the visible difference.

## 7. Network

Streaming over a 2.4 GHz hotspot on a shared channel does not work: latency
sat at 4-5 ms and spiked to 70-95 ms, and Steam flagged `(network)` as the
limiting stage. Moving the AP to a clean 5 GHz channel removed it.

    nmcli con modify <profile> 802-11-wireless.band a 802-11-wireless.channel 44
    nmcli con up <profile>

Pick a non-DFS channel (36/40/44/48 under ETSI) that does not sit inside a
neighbour's 80 MHz block, and leave the width at 20 MHz if neighbours are
close -- bandwidth was never the constraint, contention was. Keep `band` and
`channel` together: changing the band alone can land on a DFS channel that
takes a minute to come up or fails.

Also turn the screen lock off before a session. Blocking sleep is not enough;
the lock screen is a separate mechanism and will stop capture.

## Reading the numbers

`~/.local/share/Steam/logs/streaming_log.txt` reports per-stage milliseconds:

    timing: game, capture, convert, encode, network, decode, display  (bottleneck)

Steam names the limiting stage in brackets, and only logs `Slow framerate`
when there is one. Trust that over guesswork -- chasing the encoder while the
log said `(network)` wasted real time here.

## A dead end, recorded so it is not repeated

While the software path was in use, `capture` sat at a near-constant 13.69 ms
and HDR was suspected: the framebuffer is HDR/wide-gamut while Steam was
encoding 8-bit SDR NV12, so every frame needed tone-mapping. It was never
demonstrated, and once capture moved to `RGB DMABUF` the figure no longer
applies. Do not disable HDR on a hunch -- and if you do, note that
`kscreen-doctor output.<name>.hdr.disable` leaves wide colour gamut enabled,
which feeds wide-gamut content to the panel with no tone mapping and looks
genuinely awful. Set `wcg` with it, in one invocation.
