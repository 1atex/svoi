import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import wave

import numpy as np


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('music', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    sample_rate = 48000
    duration = 12
    source_start = 36.11
    decoded = subprocess.run([
        'ffmpeg', '-v', 'error', '-ss', str(source_start), '-i', str(args.music),
        '-t', str(duration), '-ac', '2', '-ar', str(sample_rate),
        '-f', 'f32le', 'pipe:1',
    ], capture_output=True, check=True)
    music = np.frombuffer(decoded.stdout, dtype=np.float32).reshape(-1, 2).copy()
    assert len(music) == sample_rate * duration
    clock = np.arange(len(music)) / sample_rate
    gain = np.interp(clock,
        [0, .02, 3.8, 4, 7, 7.12, 8.8, 9, 11.8, 12],
        [0, .55, .55, .85, .85, .38, .38, .72, .6, 0])
    music *= gain[:, None]
    rng = np.random.default_rng(24)
    for moment in [.78, 1.49, 2.65, 3.08, 4.78, 6.87, 7.68, 8.6]:
        count = int(sample_rate * .035)
        t = np.arange(count) / sample_rate
        pulse = (.018 * np.sin(2 * np.pi * 1350 * t) + .006 * rng.standard_normal(count))
        pulse *= np.exp(-t * 165) * np.minimum(t / .001, 1)
        start = round(moment * sample_rate)
        music[start:start + count] += pulse[:, None]
    peak = float(np.abs(music).max())
    if peak > .89:
        music *= .89 / peak
    pcm = np.clip(music * 32767, -32768, 32767).astype('<i2')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(args.output), 'wb') as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(pcm.tobytes())
    metadata = {
        'title': 'Better Times are Coming',
        'artist': 'Alejandro Magana (A. M.)',
        'source': 'https://assets.mixkit.co/music/173/173.mp3',
        'catalog': 'https://mixkit.co/free-stock-music/tag/technology/',
        'license': 'https://mixkit.co/license/modal/musicFree/',
        'source_sha256': hashlib.sha256(args.music.read_bytes()).hexdigest(),
        'source_start_seconds': source_start,
        'duration_seconds': duration,
        'sample_rate': sample_rate,
        'bpm_measured': 120,
        'tempo_changed': False,
        'peak_dbfs': round(float(20 * np.log10(np.abs(music).max())), 2),
        'edits': '12-second sync excerpt; volume automation; original synthesized UI clicks',
    }
    args.output.with_suffix('.json').write_text(json.dumps(metadata, indent=2), encoding='utf-8')
    print(json.dumps(metadata, ensure_ascii=True))


if __name__ == '__main__':
    main()
