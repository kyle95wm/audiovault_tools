#!/usr/bin/env python3

import os
import argparse
import subprocess
import tempfile

# Loudness profile
PROFILE = {"LUFS": -16.3, "TP": -2.6, "LRA": 5}

# Default asset paths
AVO_HEAD_PATH = os.path.expanduser("~/audio-vault-assets/avo_head.mp3")
AVO_TAIL_PATH = os.path.expanduser("~/audio-vault-assets/avo_tail.mp3")
SILENCE_PATH = os.path.expanduser("~/audio-vault-assets/silence_1s.mp3")

def generate_silence(path, dry_run=False):
    cmd = [
        "ffmpeg", "-y",
        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
        "-t", "1",
        "-acodec", "libmp3lame", "-b:a", "192k",
        path
    ]
    if dry_run:
        print("Dry run:", " ".join(cmd))
    else:
        subprocess.run(cmd, check=True)

def ensure_stereo_cbr(input_path, output_path, dry_run=False):
    cmd = [
        "ffmpeg", "-y", "-i", input_path,
        "-ar", "48000", "-ac", "2", "-b:a", "192k",
        output_path
    ]
    if dry_run:
        print("Dry run:", " ".join(cmd))
    else:
        subprocess.run(cmd, check=True)

def process_file(input_file, output_file, add_bumper=False, skip_bumper=False, dry_run=False, custom_head=None, no_tail=False):
    temp_mastered = tempfile.mktemp(suffix=".mp3")

    if not add_bumper:
        cmd = [
            "ffmpeg", "-y", "-i", input_file,
            "-af", f"acompressor=threshold=-18dB:ratio=3:attack=10:release=200,"
                   f"loudnorm=I={PROFILE['LUFS']}:LRA={PROFILE['LRA']}:TP={PROFILE['TP']}",
            "-c:a", "libmp3lame", "-b:a", "192k", "-ar", "48000", "-ac", "2",
            temp_mastered
        ]
        if dry_run:
            print("Dry run:", " ".join(cmd))
        else:
            subprocess.run(cmd, check=True)
    else:
        temp_mastered = input_file

    if skip_bumper:
        cmd = ["ffmpeg", "-y", "-i", temp_mastered, "-c", "copy", output_file]
        if dry_run:
            print("Dry run:", " ".join(cmd))
        else:
            subprocess.run(cmd, check=True)
        return

    if no_tail and not custom_head:
        raise ValueError("--no-tail requires --custom-head")

    # Handle silence file
    if not os.path.exists(SILENCE_PATH):
        print("Silence file not found, generating...")
        if not dry_run:
            os.makedirs(os.path.dirname(SILENCE_PATH), exist_ok=True)
        generate_silence(SILENCE_PATH, dry_run=dry_run)

    silence_fixed = tempfile.mktemp(suffix=".mp3")
    ensure_stereo_cbr(SILENCE_PATH, silence_fixed, dry_run=dry_run)

    head_fixed = tempfile.mktemp(suffix=".mp3")
    tail_fixed = tempfile.mktemp(suffix=".mp3")

    # Head bumper (custom or default)
    if custom_head:
        ensure_stereo_cbr(custom_head, head_fixed, dry_run=dry_run)
    else:
        if not os.path.exists(AVO_HEAD_PATH):
            raise FileNotFoundError("Missing asset: AVO_HEAD_PATH")
        ensure_stereo_cbr(AVO_HEAD_PATH, head_fixed, dry_run=dry_run)

    # Tail bumper
    if not no_tail:
        if not os.path.exists(AVO_TAIL_PATH):
            raise FileNotFoundError("Missing asset: AVO_TAIL_PATH")
        ensure_stereo_cbr(AVO_TAIL_PATH, tail_fixed, dry_run=dry_run)

    concat_list = tempfile.mktemp(suffix=".txt")
    with open(concat_list, "w") as f:
        f.write(f"file '{head_fixed}'\n")
        f.write(f"file '{temp_mastered}'\n")
        if not no_tail:
            f.write(f"file '{silence_fixed}'\n")
            f.write(f"file '{tail_fixed}'\n")
            f.write(f"file '{silence_fixed}'\n")

    cmd_concat = [
        "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", concat_list,
        "-c", "copy", output_file
    ]
    if dry_run:
        print("Dry run:", " ".join(cmd_concat))
    else:
        subprocess.run(cmd_concat, check=True)

    for path in [head_fixed, tail_fixed, silence_fixed, concat_list]:
        if os.path.exists(path):
            if dry_run:
                print(f"Dry run: would remove {path}")
            else:
                os.remove(path)
    if not add_bumper and temp_mastered != input_file and os.path.exists(temp_mastered):
        if dry_run:
            print(f"Dry run: would remove {temp_mastered}")
        else:
            os.remove(temp_mastered)

    print("Mastering complete:", output_file)

def main():
    parser = argparse.ArgumentParser(description="AudioVault Mastering Tool")
    parser.add_argument("input", help="Input WAV or MP3 file")
    parser.add_argument("output", help="Output MP3 file")
    parser.add_argument("--add-bumper", action="store_true", help="Add bumper to pre-mastered MP3")
    parser.add_argument("--skip-bumper", action="store_true", help="Skip bumper entirely")
    parser.add_argument("--custom-head", help="Path to a custom head bumper WAV or MP3")
    parser.add_argument("--no-tail", action="store_true", help="Don’t include tail bumper (requires --custom-head)")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without running them")
    args = parser.parse_args()

    process_file(
        args.input, args.output,
        add_bumper=args.add_bumper,
        skip_bumper=args.skip_bumper,
        dry_run=args.dry_run,
        custom_head=args.custom_head,
        no_tail=args.no_tail
    )

if __name__ == "__main__":
    main()
