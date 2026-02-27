# LED Pillar — Future Ideas

Ideas and upgrade paths extracted from completed features. These are not planned for implementation but documented for reference.

---

## Audio Quality Upgrades

The current audio output uses the ESP32's built-in 8-bit DAC on GPIO25 at 22050 Hz mono. This works well for lo-fi synthesized tones but has limitations (~48 dB dynamic range). Two upgrade paths exist:

### External I2S DAC (16-bit)

Add a small I2S DAC breakout board (e.g., PCM5102, MAX98357A, ~$2) for 16-bit output. The software architecture (ring buffer, DSL audio block, I2S driver) stays the same — only the I2S config and sample format change. This is the recommended upgrade if 8-bit quality becomes limiting.

### Bluetooth A2DP (Wireless Audio)

Stream audio wirelessly to the Dayton Audio amplifier via Bluetooth A2DP/SBC.

**Caveats:**
- **Flash impact**: +350–500 KB for `libbt.a`. Current firmware is ~891 KB in a ~1 MB OTA partition — **will NOT fit with OTA enabled**
- **Mitigation**: Switch to single-factory partition (no OTA) or use a larger flash chip
- **RAM impact**: +50–100 KB heap (free heap at boot is currently ~85 KB)
- **Audio format**: 44100 Hz, 16-bit stereo (A2DP/SBC requirement)

This is only worth pursuing if wireless audio to the amplifier is specifically desired and the flash/RAM constraints can be resolved.
