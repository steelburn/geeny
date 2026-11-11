"""Make a spoken Ogg Opus clip to test on-device transcription with.

The recorder writes **Ogg Opus, mono, 16 kHz**. To check the phone's own decode →
whisper path without the hardware, this makes a clip in exactly that shape: text
is spoken by the Windows voice, then re-encoded to Ogg Opus at 16 kHz mono with
libsndfile.

    uv run --with soundfile --with numpy python scripts/make_test_clip.py \
        out.ogg --text "The sampling plan is due on Friday. ..."

Windows only (System.Speech). On other systems, record a take and use that.
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import tempfile

DEFAULT_TEXT = (
    "We reviewed the sampling plan for the northern plot. "
    "The field data looks consistent with last quarter. "
    "We need to finish the sampling plan before Friday. "
    "Marta will send the revised schedule to the lab. "
    "The budget review is scheduled for next month."
)


def speak_to_wav(text: str, out: pathlib.Path) -> None:
    """Speak [text] into a 16 kHz mono 16-bit WAV with the Windows voice."""
    script = f"""
Add-Type -AssemblyName System.Speech
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(
    16000,
    [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,
    [System.Speech.AudioFormat.AudioChannel]::Mono)
$synth.SetOutputToWaveFile('{out}', $fmt)
$synth.Speak([Console]::In.ReadToEnd())
$synth.Dispose()
"""
    result = subprocess.run(
        ["powershell", "-NoProfile", "-Command", script],
        input=text.encode("utf-8"),
        capture_output=True,
    )
    if result.returncode != 0 or not out.exists():
        raise SystemExit(
            "could not speak the clip (System.Speech is Windows only):\n"
            + result.stderr.decode("utf-8", "replace")
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out", type=pathlib.Path, help="output .ogg")
    parser.add_argument("--text", default=DEFAULT_TEXT, help="what the voice says")
    args = parser.parse_args()

    import soundfile as sf  # a --with dependency; imported after arg parsing

    with tempfile.TemporaryDirectory() as tmp:
        wav = pathlib.Path(tmp) / "speech.wav"
        speak_to_wav(args.text, wav)
        samples, rate = sf.read(wav, dtype="float32")
        sf.write(args.out, samples, rate, format="OGG", subtype="OPUS")

    info = sf.info(args.out)
    print(f"{args.out} — {info.duration:.1f}s, {info.samplerate} Hz, "
          f"{info.channels} channel(s), {info.format}/{info.subtype}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
