#!/usr/bin/env python3

import os
import argparse
import subprocess
import tempfile

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

def concat_parts(parts, output_file):
    concat_txt = tempfile.mktemp(suffix=".txt")
    with open(concat_txt, "w") as f:
        for part in parts:
            f.write(f"file '{part}'\n")

    subprocess.run([
        "ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", concat_txt,
        "-c", "copy", output_file
    ], check=True)

    os.remove(concat_txt)

def add_bumpers(input_file, output_file, force=False):
    if os.path.exists(output_file) and not force:
        print(f"Skipping {output_file} (already exists)")
        return

    if not os.path.exists(AVO_HEAD_PATH) or not os.path.exists(AVO_TAIL_PATH):
        raise FileNotFoundError("Bumper files missing")

    if not os.path.exists(SILENCE_PATH):
        print("Generating 1s silence...")
        os.makedirs(os.path.dirname(SILENCE_PATH), exist_ok=True)
        generate_silence(SILENCE_PATH)

    head = tempfile.mktemp(suffix=".mp3")
    tail = tempfile.mktemp(suffix=".mp3")
    silence = tempfile.mktemp(suffix=".mp3")
    ensure_stereo_cbr(AVO_HEAD_PATH, head)
    ensure_stereo_cbr(AVO_TAIL_PATH, tail)
    ensure_stereo_cbr(SILENCE_PATH, silence)

    concat_parts([head, input_file, silence, tail, silence], output_file)

    for path in [head, tail, silence]:
        os.remove(path)

    print("Finished:", output_file)

def process_and_bumper(input_file, output_file, force=False):
    if os.path.exists(output_file) and not force:
        print(f"Skipping {output_file} (already exists)")
        return

    temp_mp3 = tempfile.mktemp(suffix=".mp3")

    subprocess.run([
        "ffmpeg", "-y", "-i", input_file,
        "-af", f"acompressor=threshold=-18dB:ratio=3:attack=10:release=200,"
               f"loudnorm=I={PROFILE['LUFS']}:LRA={PROFILE['LRA']}:TP={PROFILE['TP']}",
        "-c:a", "libmp3lame", "-b:a", "192k", "-ar", "48000", "-ac", "2",
        temp_mp3
    ], check=True)

    add_bumpers(temp_mp3, output_file, force=force)
    os.remove(temp_mp3)

def run_batch(in_dir, out_dir, add_bumper_mode, force=False):
    os.makedirs(out_dir, exist_ok=True)
    files = sorted(os.listdir(in_dir))

    for f in files:
        ext = os.path.splitext(f)[1].lower()
        if add_bumper_mode and ext != ".mp3":
            continue
        if not add_bumper_mode and ext != ".wav":
            continue

        in_path = os.path.join(in_dir, f)
        out_path = os.path.join(out_dir, os.path.splitext(f)[0] + ".mp3")

        try:
            if add_bumper_mode:
                add_bumpers(in_path, out_path, force=force)
            else:
                process_and_bumper(in_path, out_path, force=force)
        except subprocess.CalledProcessError as e:
            print(f"Failed on {f}: {e}")

def main():
    parser = argparse.ArgumentParser(description="AudioVault Mastering Tool")
    parser.add_argument("input", help="Input file or folder")
    parser.add_argument("output", nargs="?", help="Output file or folder")
    parser.add_argument("--add-bumper", action="store_true", help="Add bumpers to existing MP3")
    parser.add_argument("--batch", action="store_true", help="Batch mode (input/output are folders)")
    parser.add_argument("--force", action="store_true", help="Overwrite existing output files")
    args = parser.parse_args()

    if args.batch:
        if not args.output or not os.path.isdir(args.input):
            print("Batch mode requires two folders: in out")
            return
        run_batch(args.input, args.output, args.add_bumper, force=args.force)
    else:
        if not args.output or not os.path.isfile(args.input):
            print("Single file mode requires input file and output file.")
            return
        if args.add_bumper and not args.input.lower().endswith(".mp3"):
            print("With --add-bumper, input must be an MP3.")
            return
        if not args.add_bumper and not args.input.lower().endswith(".wav"):
            print("Input must be a WAV unless --add-bumper is used.")
            return

        if args.add_bumper:
            add_bumpers(args.input, args.output, force=args.force)
        else:
            process_and_bumper(args.input, args.output, force=args.force)

if __name__ == "__main__":
    main()
