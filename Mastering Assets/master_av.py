#!/usr/bin/env python3

import os
import argparse
import subprocess
import tempfile
import sys

# Loudness profile
PROFILE = {"LUFS": -16.3, "TP": -2.6, "LRA": 5}

# Default asset paths
DEFAULT_HEAD = os.path.expanduser("~/audio-vault-assets/avo_head.mp3")
DEFAULT_TAIL = os.path.expanduser("~/audio-vault-assets/avo_tail.mp3")
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

def validate_args(args):
    if args.skip_bumper and (args.custom_head or args.custom_tail or args.no_head or args.no_tail):
        sys.exit("Error: --skip-bumper cannot be used with bumper options like --custom-head or --no-tail")
    if args.no_head and args.custom_head:
        sys.exit("Error: --no-head cannot be used with --custom-head")
    if args.no_tail and args.custom_tail:
        sys.exit("Error: --no-tail cannot be used with --custom-tail")

def process_file(input_file, output_file, add_bumper=False, skip_bumper=False, dry_run=False,
                 custom_head=None, custom_tail=None, no_head=False, no_tail=False):
    validate_args(argparse.Namespace(
        skip_bumper=skip_bumper, custom_head=custom_head,
        custom_tail=custom_tail, no_head=no_head, no_tail=no_tail
    ))

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
        if not dry_run:
            os.rename(temp_mastered, output_file)
        else:
            print(f"Dry run: would rename {temp_mastered} to {output_file}")
        return

    # Prepare assets
    if not os.path.exists(SILENCE_PATH):
        print("Silence file not found, generating...")
        os.makedirs(os.path.dirname(SILENCE_PATH), exist_ok=True)
        generate_silence(SILENCE_PATH, dry_run=dry_run)

    silence_fixed = tempfile.mktemp(suffix=".mp3")
    ensure_stereo_cbr(SILENCE_PATH, silence_fixed, dry_run=dry_run)

    concat_list = tempfile.mktemp(suffix=".txt")

    with open(concat_list, "w") as f:
        if not no_head:
            head_path = custom_head or DEFAULT_HEAD
            if not os.path.exists(head_path):
                sys.exit(f"Missing head bumper: {head_path}")
            head_fixed = tempfile.mktemp(suffix=".mp3")
            ensure_stereo_cbr(head_path, head_fixed, dry_run=dry_run)
            f.write(f"file '{head_fixed}'\n")
        f.write(f"file '{temp_mastered}'\n")
        if not no_tail:
            tail_path = custom_tail or DEFAULT_TAIL
            if not os.path.exists(tail_path):
                sys.exit(f"Missing tail bumper: {tail_path}")
            tail_fixed = tempfile.mktemp(suffix=".mp3")
            ensure_stereo_cbr(tail_path, tail_fixed, dry_run=dry_run)
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

    for path in [concat_list, silence_fixed]:
        if os.path.exists(path) and not dry_run:
            os.remove(path)

    if not add_bumper and temp_mastered != input_file and os.path.exists(temp_mastered):
        if dry_run:
            print(f"Dry run: would remove {temp_mastered}")
        else:
            os.remove(temp_mastered)

    print("Mastering complete:", output_file)

def run_batch(in_dir, out_dir, add_bumper=False, skip_bumper=False, force=False, dry_run=False,
              custom_head=None, custom_tail=None, no_head=False, no_tail=False):
    for filename in os.listdir(in_dir):
        input_path = os.path.join(in_dir, filename)
        if not os.path.isfile(input_path):
            continue
        name, ext = os.path.splitext(filename)
        if ext.lower() not in [".wav", ".mp3"]:
            continue
        output_path = os.path.join(out_dir, name + ".mp3")
        if os.path.exists(output_path) and not force:
            print("Skipping existing file:", output_path)
            continue
        print("Processing:", input_path)
        process_file(input_path, output_path, add_bumper=add_bumper, skip_bumper=skip_bumper,
                     dry_run=dry_run, custom_head=custom_head, custom_tail=custom_tail,
                     no_head=no_head, no_tail=no_tail)

def main():
    parser = argparse.ArgumentParser(description="AudioVault Mastering Tool")
    parser.add_argument("input", nargs="?", help="Input file or folder")
    parser.add_argument("output", nargs="?", help="Output file or folder")
    parser.add_argument("--add-bumper", action="store_true", help="Only add bumpers to existing MP3s")
    parser.add_argument("--skip-bumper", action="store_true", help="Do not add bumpers")
    parser.add_argument("--custom-head", help="Path to custom head bumper (WAV or MP3)")
    parser.add_argument("--custom-tail", help="Path to custom tail bumper (WAV or MP3)")
    parser.add_argument("--no-head", action="store_true", help="Omit head bumper")
    parser.add_argument("--no-tail", action="store_true", help="Omit tail bumper")
    parser.add_argument("--batch", action="store_true", help="Batch mode (input/output folders)")
    parser.add_argument("--force", action="store_true", help="Force overwrite")
    parser.add_argument("--dry-run", action="store_true", help="Print what would be done without executing")

    args = parser.parse_args()
    validate_args(args)

    if args.batch:
        in_dir = args.input or "./in"
        out_dir = args.output or "./out"
        if not os.path.isdir(in_dir):
            sys.exit(f"Missing input folder: {in_dir}")
        if not os.path.isdir(out_dir):
            if args.dry_run:
                print(f"Dry run: would create folder {out_dir}")
            else:
                os.makedirs(out_dir)
        run_batch(in_dir, out_dir, add_bumper=args.add_bumper, skip_bumper=args.skip_bumper,
                  force=args.force, dry_run=args.dry_run, custom_head=args.custom_head,
                  custom_tail=args.custom_tail, no_head=args.no_head, no_tail=args.no_tail)
    else:
        if not args.input or not args.output:
            sys.exit("In single mode, both input and output files must be specified.")
        if not os.path.isfile(args.input):
            sys.exit("Invalid input file.")
        process_file(args.input, args.output, add_bumper=args.add_bumper,
                     skip_bumper=args.skip_bumper, dry_run=args.dry_run,
                     custom_head=args.custom_head, custom_tail=args.custom_tail,
                     no_head=args.no_head, no_tail=args.no_tail)

if __name__ == "__main__":
    main()
