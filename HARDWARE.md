# What this assumes about the machine

Every toggle works from config with defaults that suit one particular PC. This
file says what that PC is, and which toggles care -- so if yours differs you
can see what to change rather than finding out when something misbehaves.

Nothing here needs editing to *run*. The defaults are chosen so a wrong guess
degrades to "feature reports unavailable" rather than to wrong behaviour.

## The reference machine

| | |
|---|---|
| CPU | Ryzen 7 9700X (has an iGPU -- relevant below) |
| GPU | Radeon RX 9070 XT, 16 GB, `gfx1201` (`1002:7550`) |
| Board | MSI MAG B850M MORTAR WIFI |
| Wi-Fi | Qualcomm WCN7850, `ath12k` |
| Mouse | Logitech G502 Lightspeed |
| Audio | Bluetooth headset |
| OS | Fedora 44, KDE Plasma on Wayland, kernel 7.1.x |

## Toggles that touch hardware

### GPU -- `14-llm`, `25-powercap`, `80-desktop`

The discrete card is **found, not hardcoded**: `vc_gpu_card` picks the DRM card
with the largest `mem_info_vram_total`, which is the dGPU on any machine that
has one. An iGPU reports 0 there. This matters because DRM numbering follows
probe order -- on this machine the iGPU is `card0` and the dGPU is `card1`, but
a CPU without an iGPU puts the dGPU on `card0`.

    gpu.card = card0        override if autodetection ever picks wrong

Only `amdgpu` exposes `mem_info_vram_*`. On an NVIDIA or Intel card nothing is
found and the VRAM gates fall back to "no card, nothing to wait for" -- the
features still work, they just stop pre-checking whether the card is free.

`25-powercap` needs **LACT** with two profiles that differ only in `power_cap`,
named by `powercap.profile_on` / `powercap.profile_off`. The daemon socket
`/run/lactd.sock` must be readable by your user; LACT's `admin_group` is
normally `wheel`. The power figures in that file (221 W / 307 W, and the ~5%
throughput cost) are measurements from this card, not settings.

### Swap -- `16-swap`

Assumes Fedora's `zram-generator-defaults`, which creates `/dev/zram0`.

    swap.unit        = dev-zram0.swap
    swap.max_used_mb = 2048

On a machine with a disk swap partition instead, point `swap.unit` at that
`.swap` unit -- though the reason this toggle exists is specific to zram, where
swap costs RAM rather than disk. See the comment at the top of the toggle.

### Local LLM -- `14-llm`

    llm.bin    = $HOME/opt/llama-vulkan/bin/llama-server
    llm.device = Vulkan0

A llama.cpp build, Vulkan by default because on this card it measured
substantially faster than ROCm -- the table is in the toggle. Both backends
enumerate the iGPU as a second device, which is why `-dev` is always passed.
Model paths and every sampling parameter are per-profile config; nothing about
a specific model is baked in.

### Mouse -- `21-mousealt`

Defaults describe a G502, which presents *two* USB identities depending on
whether its charging cable is in:

    mousealt.device = Logitech G502,Logitech G502 LIGHTSPEED Wireless Gaming Mouse
    mousealt.usb_id = 046d:c539,046d:c08d
    mousealt.button = BTN_SIDE

Both are driven unconditionally rather than detected, because the receiver's
node lingers while the mouse runs wired. For another mouse, set all three --
check the button with `evtest`, since a mouse with programmed onboard memory
can send anything. Needs **input-remapper**.

### Hotspot -- `11-hotspot`

    hotspot.connection = Hotspot

NetworkManager's default name for a shared connection. The connection itself is
yours to create; this only brings it up and down.

### WoW remote play -- `60-wow`

The most machine-specific feature here, and the one most likely to want all
four keys changed:

    wow.prefix     globbed out of Steam's compatdata -- the id in that path is
                   generated per user, so it is never hardcoded
    wow.res_on     the *client's* drawable area   (3024x1898 here)
    wow.res_off    the host's own panel           (2560x1440 here)
    wow.seed_on / wow.seed_off    cvars for a Config.wtf that does not exist yet

Needs `kscreen-doctor`, so KDE specifically.

### Desktop -- `80-desktop`

KDE Plasma on Wayland: `plasmalogin`, `kscreen-doctor`, and Plasma's own logout
D-Bus call. Assumes autologin on `tty1`, hence the `getty@tty1.service`
handling. A different login manager needs `install/desktop-privileges.sh`
rewritten.

### Headset mic -- `22-airpods`

Generic: one wireplumber setting, `bluetooth.autoswitch-to-headset-profile`.
The toggle id is historical; it is not AirPods-specific.

## Things that are measurements, not configuration

Several toggles carry numbers in comments -- throughput at a given power cap,
compression ratios, VRAM at a given context. Those are what this hardware did,
recorded so a later change can be compared against something. They are not
tuned values and copying them to different hardware proves nothing.
