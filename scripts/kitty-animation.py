#!/usr/bin/env python3
"""Display a short Kitty graphics protocol animation for manual testing."""

import argparse
import base64
import sys
import time


ESC = "\x1b_G"
ST = "\x1b\\"
IMAGE_ID = 0x4D4F4E
WIDTH = 24
HEIGHT = 12


def frame(left: tuple[int, int, int], right: tuple[int, int, int]) -> str:
    pixels = bytearray()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            color = left if x < WIDTH // 2 else right
            if (x // 3 + y // 3) % 2:
                color = tuple(channel // 2 for channel in color)
            pixels.extend((*color, 255))
    return base64.b64encode(pixels).decode("ascii")


def command(control: str, payload: str = "") -> None:
    sys.stdout.write(f"{ESC}{control};{payload}{ST}")
    sys.stdout.flush()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=8, help="display duration (default: 8)")
    args = parser.parse_args()

    frames = (
        frame((255, 60, 60), (40, 100, 255)),
        frame((40, 220, 100), (255, 180, 20)),
        frame((180, 60, 255), (20, 220, 220)),
    )

    print("Kitty animation smoke test: the two checkerboard panels should change color four times per second.")
    command(f"a=T,f=32,s={WIDTH},v={HEIGHT},i={IMAGE_ID},c=12,r=6,q=2", frames[0])
    command(f"a=f,f=32,s={WIDTH},v={HEIGHT},i={IMAGE_ID},z=250,q=2", frames[1])
    command(f"a=f,f=32,s={WIDTH},v={HEIGHT},i={IMAGE_ID},z=250,q=2", frames[2])
    command(f"a=a,i={IMAGE_ID},r=1,z=250,s=3")

    try:
        time.sleep(max(args.seconds, 0))
    finally:
        command(f"a=d,d=I,i={IMAGE_ID},q=2")
        print("\nAnimation smoke test complete.")


if __name__ == "__main__":
    main()
