---
id: full-analysis
aliases: []
tags: []
---
## Complete root cause analysis of the touchpad issue

The touchpad device `TPD0` (`_HID=TOPS0102` / `_CID=PNP0C50`) is **not** in the
DSDT. It lives in an SSDT named `I2C_DEVT` (`ssdt27` in the acpidump). That table
**fails to load** because of a single line of **module-level** code:

```asl
Device (NFC0) {            // NFC tag (NTAG0001) on I2C1 — no Linux driver, optional
    ...
    INT1 = GNUM (0x001A088A)   // <-- module-level: runs immediately at table load
}
```

`GNUM → \_SB.GINF` performs `Index` operations on the `GPCS` package during table
load, hitting a firmware bug:

```
ACPI Error: No pointer back to namespace node in package ... (dsargs)
ACPI Error: AE_AML_INTERNAL, While resolving operands for [Index]
ACPI Error: Aborting method \_SB.GINF / \_SB.GNUM / \   (module level)
ACPI Error: AE_AML_INTERNAL, (SSDT:I2C_DEVT) while loading table
ACPI Error: 1 table load failures, NN successful
```

**The whole table is rolled back → `TPD0` is never created → the touchpad never
enumerates.** That is why `/proc/bus/input/devices` shows only USB mice and the
i2c-0/i2c-1 (Synopsys DesignWare / Intel LPSS) buses have zero devices attached.
Windows' ACPI interpreter tolerates this early access, so the touchpad works
under the factory OS.

## Diagnosis trail (symptom → root cause)

Every step is reproducible offline with `acpi-tables-from-boot7/`.

### Step 1 — Confirm the device never appears (vs. "appears but no driver")

`/proc/bus/input/devices` lists only USB mice, the keyboard, and lid/power
buttons — **no built-in I2C touchpad**. The `i2c-0`/`i2c-1` controllers exist but
have **zero** devices on them.
→ Not an input/HID-driver issue; the device is simply never enumerated by ACPI.

### Step 2 — Look for the touchpad in the DSDT → it isn't there

The DSDT has no `PNP0C50` touchpad. Under `\_SB.PC00.I2C1` there are only audio
codecs (`10EC1308`/`INT34C2`), all gated behind `If (I2SB==…)`. The touchpad must
be defined dynamically in some SSDT.

### Step 3 — Scan every SSDT → touchpad is in ssdt27 (`I2C_DEVT`)

```bash
for s in acpi-tables-from-boot7/ssdt*.dat; do
  strings "$s" | grep -qE "PNP0C50|TOPS|TPD0" && echo "$s"
done
# => ssdt27.dat   (Device(TPD0), _HID=TOPS0102/PNP0C50, I2C1@0x5D)
```

`dmesg | grep DMI` confirms **HONOR XWC-P / Panther Lake / BIOS 1.09**, touchpad
chip **TOPS0102** — different from the reference FMB-P / Arrow Lake / ELAN9048,
explaining why the reference patch never worked.

### Step 4 — Read the dmesg error → it crashes during table load

dmesg shows the same error set on every boot (a stable firmware bug):

```
ACPI Error: AE_AML_INTERNAL, While resolving operands for [Index]
ACPI Error: Aborting method \_SB.GINF
ACPI Error: Aborting method \_SB.GNUM
ACPI Error: Aborting method \                      <- call-stack top is "\" (module level)
ACPI Error: AE_AML_INTERNAL, (SSDT:I2C_DEVT) while loading table
```

The failing table is `I2C_DEVT`, and the call-stack root is `\` — so the trigger
is **module-level code executed at table load**, not a device method invocation.

### Step 5 — Locate the module-level trigger

```bash
grep -nE "GNUM|GADR|GGPE" ssdt27-original.asl | grep -v External
# => INT1 = GNUM (0x001A088A)   (inside Device(NFC0), module level, not in a method)
```

`GNUM → GADR/GINF` (defined in the DSDT) does nested `Index/DerefOf` on `GPCS`:

```asl
Method (GINF, 3) { Local0 = GDSC();   // GDSC returns \_SB.GPCS
    Return (DerefOf(DerefOf(DerefOf(DerefOf(Local0[Arg0])[One])[Arg1])[Arg2])) }
```

### Step 6 — Reproduce with acpiexec for a more precise error

```bash
cd acpi-tables-from-boot7
acpiexec -b 'quit' dsdt.dat ssdt{1..27}.dat
```

```
ACPI Error: No pointer back to namespace node in package 0x... (dsargs-364)
ACPI Error: AE_AML_INTERNAL, While resolving operands for [Index]
Failed at AML Offset 0000C, Opcode 0088: Index (-Return Value- (), One)   <- GINF's 2nd level [One]
```

> The real firmware bug: during **table load**, the sub-packages of `GPCS` do not
> yet have their "back pointer to the namespace node", so `Index` fails. HONOR's
> BIOS placed a heavy `GNUM(...)` computation at SSDT module level, running before
> the namespace is ready — tolerated by Windows, rejected by Linux/ACPICA.

### Step 7 — Verify "drop that line and it loads", then measure the real resources

After removing the module-level `INT1 = GNUM(0x001A088A)` and recompiling:

```
ACPI: NN ACPI AML tables successfully acquired and loaded    <- 0 failures
```

Then, at **runtime** (namespace ready, GNUM works), measure the touchpad's
interrupt and resources:

```bash
acpiexec -b 'execute \_SB.GNUM 0x001A0894' dsdt.dat ssdt{1..26}.dat <fixed ssdt27>
#   => 0x23 (=35)   touchpad interrupt pin
acpiexec -b 'execute \_SB.PC00.I2C1.TPD0._CRS' ...
#   => 46 bytes: I2cSerialBusV2(0x5D,"\_SB.PC00.I2C1") + GpioInt(Level,ActiveLow, GPI3){0x23}
```

Three-way cross-check (offline GPCS decode = runtime `GNUM` = `_CRS` buffer) all
give pin = 35.

## Measured touchpad resources (acpiexec runtime, three-way cross-checked)

| Field | Value | Source |
|---|---|---|
| _HID | `TOPS0102` | ssdt27 `TPDT==1` branch |
| _CID | `PNP0C50` | generic i2c-hid match |
| I2C | addr `0x5D` @ `\_SB.PC00.I2C1`, 400 kHz | measured `_CRS` |
| Interrupt | `GpioInt(Level, ActiveLow)` pin `0x23` (35) @ `\_SB.GPI3` | `_CRS` + `GNUM(0x001A0894)=0x23` |
| HID descriptor register | `0x0001` | `_DSM` HIDG fn1 (HID2) |

## Why the `GADR/INUM → GNUM → GINF` path fails — and whether it can be fixed

### Exact mechanism: not a logic bug, a **timing** bug

Call chain: `GNUM(gpio) → GINF(com,grp,7) → GDSC() → 4-level Index/DerefOf on GPCS`.

```asl
Method (GDSC) { Return (GPCS) }                 // GPCS is a static Name(Package(){...})
Method (GINF, 3) { Local0 = GDSC ()
    Return (DerefOf(DerefOf(DerefOf(DerefOf(Local0[Arg0])[One])[Arg1])[Arg2])) }
```

The keyword **"No pointer back to namespace node in package"**: `Index(GPCS, …)`
requires the indexed Package to carry a back-pointer to its namespace node.
`GPCS` is a **nested** Package; the sub-package fetched at the 2nd level `[One]`
has not established that back-pointer **before the namespace finishes loading**.
Because HONOR put `INT1 = GNUM(...)` at **module level** (in the device body, not
in a method), it runs during table load, when the namespace isn't ready →
`Index` fails → `AE_AML_INTERNAL` → the whole table is rolled back.

> In one sentence: **the AML logic is correct; it's just placed at a moment when
> it cannot yet run.**

### Decisive control experiments (all reproducible with `acpi-tables-from-boot7/`)

| Experiment | Result |
|---|---|
| Original `GNUM(0x001A088A)` at module-level load time | **crash**: `No pointer back to namespace node` |
| Same call at **runtime** (`execute \_SB.GNUM 0x001A088A` after load) | **succeeds**, returns `0x19` (25) |
| Runtime `execute \_SB.GDSC` | returns the full 5-level nested Package |
| Runtime `execute \_SB.GINF 2 1 7` | returns `0x0F` |

**Same code, same argument: crashes at load, works at runtime** → confirms it's
purely a timing problem.

### Yes, it can be fixed — minimally

Since the only problem is "module level = too early", moving that one line into a
method that runs at runtime (e.g. `_CRS`) fixes it without touching any GPIO
logic and without hardcoding any pin. **This is variant C** (deployed).

## The three variants

All three append a fixed table via initrd ACPI override and **rename the OEM
Table ID** so the kernel treats it as a *new* table (see the warning below). The
BIOS original `I2C_DEVT` still fails and rolls back; that lone `1 table load
failure` / `AE_AML_INTERNAL` line in dmesg is harmless.

### Variant C — move one line (DEPLOYED) ★

`ssdt27-C.asl` / `.aml`, image `acpi_override_C.img`, OEM Table ID `I2CDEVC`.

Move NFC0's module-level `INT1 = GNUM(0x001A088A)` into `NFC0._CRS` (runtime).
**`TPD0` is left completely untouched** — it keeps the OEM dynamic GPIO
computation, the original `_STA` (TPDT check), and the original `_HID` logic
(`TPDT==1 → TOPS0102`). The one-line diff is `ssdt27-C.patch`.

Verified offline: table loads with 0 added failures; the untouched
`TPD0._INI`/`_CRS` (which still call `INUM/SGRA/SHPO/G_IN → GNUM`) run correctly
at runtime and `_CRS` returns the exact same 46-byte resource as the static
variant. This is the most faithful fix to the OEM design.

### Variant B — fully static TPD0

`ssdt27-B.asl` / `.aml`, image `acpi_override_B.img`, OEM Table ID `I2CDEVB`.

Removes NFC0's crashing line **and** rewrites `TPD0`'s `_INI/_CRS/_DSM` to
hardcode all resources (I2C 0x5D, GpioInt pin 35 @ GPI3, HID descriptor 0x0001),
with `_STA` always `0x0F`. More conservative — nothing touching `GPCS` runs on
the kernel's enumeration path — but it deviates from the OEM design. Useful as a
fallback if variant C ever shows a runtime-timing issue on a given firmware.

### Variant A — add a standalone static device TPDX

`tpd-A-new-device.asl` / `.aml`, image `acpi_override_A.img`, OEM Table ID `TPADD`.

Adds a brand-new static `TPDX` device under `\_SB.PC00.I2C1`; does **not** touch
the original table at all. Smallest blast radius, handy to first prove the
hardware path. Downside: device is named `TPDX`, not the OEM `TPD0`.

> Pick exactly one — do **not** enable two at once (you'd get two touchpad
> devices).

> ⚠️ **The OEM Table ID must be renamed.** If you keep the original Table ID
> (`I2C_DEVT`), the kernel's ACPI override treats the image as a **replacement**
> of the BIOS table, and the replacement path **re-executes the module-level
> code**, hitting the same GINF bug again. Renaming (to `I2CDEVC`/`I2CDEVB`/etc.)
> makes the kernel load it as a brand-new appended table. acpiexec does not model
> replace-vs-append, so this only shows up on real hardware — the single most
> important real-machine lesson here.

## What the removed/changed ACPI code did, and the impact

### Variant C: just moves one line

NFC0's `INT1 = GNUM(0x001A088A)` decoded the NFC interrupt pin (measured 25) and
wrote it into NFC0's own resource template — purely NFC housekeeping. Moving it
from module level into `NFC0._CRS` means it runs at runtime instead of at table
load. Impact on the touchpad: none (independent device). Impact on NFC: none in
practice (NTAG0001 has no Linux driver). `TPD0` is unchanged.

### Variant B additionally static-rewrites TPD0 (context, for the fallback)

The original `TPD0._INI` called `INUM/SGRA/SHPO/G_IN` (all via `GNUM→GINF`) to
configure the interrupt pad (HOSTSW_OWN, RX polarity) before enumeration. These
go through the same crashing `GPCS` path, so a static rewrite is required if you
don't move/avoid the call. Dropping them is acceptable on Linux: the interrupt
pad is reconfigured by **Intel pinctrl + the i2c-hid framework** from the
`GpioInt(Level, ActiveLow, …)` descriptor in `_CRS` anyway, so the ACPI
`SHPO/SGRA` writes are redundant under Linux. (Variant C avoids the question
entirely by keeping the OEM dynamic path and just fixing the load-time timing.)
