/*
 * Variant A: add a standalone static touchpad device (TPDX)
 *
 * Background: on the HONOR XWC-P (Panther Lake, BIOS 1.09) the touchpad device
 * TPD0 is defined in the SSDT "I2C_DEVT" (ssdt27 in the acpidump). That table
 * fails at LOAD time because of module-level code
 *   NFC0:  INT1 = GNUM (0x001A088A)
 * whose \_SB.GINF -> Index operation hits a firmware bug:
 *   "No pointer back to namespace node in package" -> AE_AML_INTERNAL
 * The whole table is rolled back, so TPD0 is never created and the touchpad
 * never enumerates.
 *
 * This variant does NOT touch the original table (which still fails to load,
 * harmlessly -- it never succeeded anyway). We add a fully static device TPDX
 * under \_SB.PC00.I2C1 with all resources hardcoded, calling none of the
 * crashing GNUM/GINF/G_IN, so i2c-hid binds directly.
 *
 * Resources come from acpiexec runtime measurement of the real ACPI tables:
 *   - I2C:  address 0x5D, controller \_SB.PC00.I2C1, 400 kHz
 *   - IRQ:  GpioInt Level/ActiveLow, pin 0x23 (35), controller \_SB.GPI3
 *   - HID descriptor register: 0x0001  (from _DSM HIDG fn1 / HID2)
 *   - _HID TOPS0102 (vendor), _CID PNP0C50 (generic HID-over-I2C match)
 */
DefinitionBlock ("", "SSDT", 2, "HONOR", "TPADD", 0x00001000)
{
    External (\_SB.PC00.I2C1, DeviceObj)

    Scope (\_SB.PC00.I2C1)
    {
        Device (TPDX)
        {
            Name (_HID, "TOPS0102")
            Name (_CID, "PNP0C50")
            Name (_S0W, 0x03)

            Name (SBFB, ResourceTemplate ()
            {
                I2cSerialBusV2 (0x005D, ControllerInitiated, 0x00061A80,
                    AddressingMode7Bit, "\\_SB.PC00.I2C1",
                    0x00, ResourceConsumer, , Exclusive,
                    )
                GpioInt (Level, ActiveLow, ExclusiveAndWake, PullDefault, 0x0000,
                    "\\_SB.GPI3", 0x00, ResourceConsumer, ,
                    )
                    {   // Pin list
                        0x0023
                    }
            })

            Method (_STA, 0, NotSerialized)
            {
                Return (0x0F)
            }

            Method (_CRS, 0, NotSerialized)
            {
                Return (SBFB)
            }

            // HID-over-I2C descriptor register address = 0x0001
            // (i2c-hid via _DSM, UUID 3cdff6f7-..., function 1)
            Name (HIDG, ToUUID ("3cdff6f7-4267-4555-ad05-b30a3d8938de"))
            Method (_DSM, 4, Serialized)
            {
                If ((Arg0 == HIDG))
                {
                    // function 0: supported-functions bitmap -> bit0+bit1
                    If ((ToInteger (Arg2) == Zero))
                    {
                        Return (Buffer (One) { 0x03 })
                    }
                    // function 1: HID descriptor register address
                    If ((ToInteger (Arg2) == One))
                    {
                        Return (0x0001)
                    }
                }
                Return (Buffer (One) { 0x00 })
            }
        }
    }
}
