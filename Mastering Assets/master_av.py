#!/usr/bin/env python3

import os
import argparse
import subprocess
import tempfile
import sys

# Loudness profile
PROFILE = {"LUFS": -16.3, "TP": -2.6, "LRA": 5}

# Asset paths
AVO_HEAD_PATH = os.path.expanduser("~/audio-vault-assets/avo_head.mp3")
AVO_TAIL_PATH = os.path.expanduser("~/audio-vault-assets/avo_tail.mp3")
SILENCE_PATH = os.path.expanduser("~/audio-vault-assets/silence_1s.mp3")

def generate_silence(path):
    subprocess.run([
        "ffmpeg", "-y",
        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
        "-t", "1",
        "-acodec", "libmp3lame", "-b:a", "192k",
        path
    ], check=True)

def ensure_stereo_cbr(input_path, output_path):
    subprocess.run([
        "ffmpeg", "-y", "-i", input_path,
        "-ar", "48000", "-ac", "2", "-b:a", "192k",
        output_path
    ], check=True)

def check_required_files():
    for asset in [AVO_HEAD_PATH, AVO_TAIL_PATH]:
        if not os.path.exists(asset):
            sys.exit(f"Error: Missing asset: {asset}")

    if not os.path.exists(SILENCE_PATH):
        print("Silence file not found, generating...")
        os.makedirs(os.path.dirname(SILENCE_PATH), exist_ok=True)
        generate_silence(SILENCE_PATH)

def process_mastering(input_file, output_file):
    temp_mastered = tempfile.mktemp(suffix=".mp3")

    subprocess.run([
        "ffmpeg", "-y", "-i", input_file,
        "-af", f"acompressor=threshold=-18dB:ratio=3:attack=10:release=200,"
               f"loudnorm=I={PROFILE['LUFS']}:LRA={PROFILE['LRA']}:TP={PROFILE['TP']}",
        "-c:a", "libmp3lame", "-b:a", "192k", "-ar", "48000", "-ac", "2",
        temp_mastered
    ], check=True)

    process_bumper(temp_mastered, output_file, delete_input=True)

def process_bumper(input_mp3, output_file, delete_input=False):
    check_required_files()

    head_fixed = tempfile.mktemp(suffix=".mp3")
    tail_fixed = tempfile.mktemp(suffix=".mp3")
    silence_fixed = tempfile.mktemp(suffix=".mp3")

    ensure_stereo_cbr(AVO_HEAD_PATH, head_fixed)
    ensure_stereo_cbr(AVO_TAIL_PATH, tail_fixed)
    ensure_stereo_cbr(SILENCE_PATH, silence_fixed)

    concat_list = tempfile.mktemp(suffix=".txt")
    with open(concat_list, "w") as f:
        f.write(f"file '{head_fixed}'\n")
        f.write(f"file '{input_mp3}'\n")
        f.write(f"file '{silence_fixed}'\n")
        f.write(f"file '{tail_fixed}'\n")
        f.write(f"file '{silence_fixed}'\n")

    if os.path.exists(output_file):
        confirm = input(f"Warning: Output file '{output_file}' exists. Overwrite? [y/N]: ").strip().lower()
        if confirm != 'y':
            print("Aborted.")
            return

    subprocess.run([
        "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", concat_list,
        "-c", "copy", output_file
    ], check=True)

    if delete_input and os.path.exists(input_mp3):
        os.remove(input_mp3)

    for path in [head_fixed, tail_fixed, silence_fixed, concat_list]:
        if os.path.exists(path):
            os.remove(path)

    print("Final MP3 created:", output_file)

def main():
    parser = argparse.ArgumentParser(description="AudioVault Mastering + Bumper Tool")
    parser.add_argument("input", help="Input audio file (.wav or .mp3 depending on mode)")
    parser.add_argument("output", help="Output MP3 file")
    parser.add_argument("--add-bumper", action="store_true", help="Only add bumpers to an already-mastered MP3")
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        sys.exit("Error: Input file does not exist.")

    if not args.output.lower().endswith(".mp3"):
        sys.exit("Error: Output must be an MP3 file.")

    if args.add_bumper:
        if not args.input.lower().endswith(".mp3"):
            sys.exit("Error: Input must be an MP3 file when using --add-bumper.")
        process_bumper(args.input, args.output)
    else:
        if not args.input.lower().endswith(".wav"):
            sys.exit("Error: Input must be a WAV file for mastering mode.")
        process_mastering(args.input, args.output)

if __name__ == "__main__":
    main()
