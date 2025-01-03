#!/usr/bin/env python3
import os
import argparse
import subprocess
import tempfile

# Supported input formats
SUPPORTED_FORMATS = ['.wav', '.mp3', '.aac', '.eac3']

# AudioVault mastering profile
AUDIOVAULT_PROFILE = {
    "LUFS": -16.3,
    "TP": -2.6,
    "LRA": 5
}

def process_file(input_file, output_file, aggressive_compression):
    # Create temp file for intermediate audio
    with tempfile.NamedTemporaryFile(delete=False, suffix=".mp3") as temp_audio:
        temp_audio_path = temp_audio.name

    # FFmpeg command to process audio
    ffmpeg_cmd = [
        "ffmpeg",
        "-i", input_file,
        "-af", f"acompressor=threshold=-24dB:ratio=4:attack=5:release=150,"
               f"acompressor=threshold=-18dB:ratio=3:attack=10:release=200,"
               f"loudnorm=I={AUDIOVAULT_PROFILE['LUFS']}:LRA={AUDIOVAULT_PROFILE['LRA']}:TP={AUDIOVAULT_PROFILE['TP']}",
        "-c:a", "libmp3lame",
        "-b:a", "192k",
        temp_audio_path
    ]

    if aggressive_compression:
        ffmpeg_cmd[3] = f"acompressor=threshold=-30dB:ratio=6:attack=2:release=100,{ffmpeg_cmd[3]}"

    try:
        # Run FFmpeg for audio processing
        subprocess.run(ffmpeg_cmd, check=True)

        # Mux processed audio back into the output file
        ffmpeg_mux_cmd = [
            "ffmpeg",
            "-i", input_file,
            "-i", temp_audio_path,
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c:v", "copy",
            "-shortest",
            output_file
        ]
        subprocess.run(ffmpeg_mux_cmd, check=True)

        # Clean up temp audio file after muxing
        os.remove(temp_audio_path)
        print("✅ Muxing completed successfully.")

    except subprocess.CalledProcessError as e:
        print(f"❌ Error processing {input_file}")
        print(e)
        if os.path.exists(temp_audio_path):
            os.remove(temp_audio_path)


def get_files_from_directory(directory):
    files = []
    for root, _, filenames in os.walk(directory):
        for filename in filenames:
            if any(filename.endswith(ext) for ext in SUPPORTED_FORMATS):
                files.append(os.path.join(root, filename))
    return files


def main():
    parser = argparse.ArgumentParser(description="AudioVault Mastering Script")
    parser.add_argument("input", help="Input file or directory")
    parser.add_argument("output", help="Output file or directory")
    parser.add_argument("--aggressive", action="store_true", help="Apply aggressive compression")
    args = parser.parse_args()

    # Check if input is directory or file
    if os.path.isdir(args.input):
        files = get_files_from_directory(args.input)
        os.makedirs(args.output, exist_ok=True)
        for file in files:
            output_file = os.path.join(args.output, os.path.basename(file).replace(".wav", ".mp3"))
            process_file(file, output_file, args.aggressive)
    elif os.path.isfile(args.input):
        process_file(args.input, args.output, args.aggressive)
    else:
        print("Invalid input. Please specify a valid file or directory.")
        return

    print("Batch processing complete!")


if __name__ == "__main__":
    main()
