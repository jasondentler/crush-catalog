import os
import re
import sys
from imgcat import imgcat
from PIL import Image
import climage

class TerminalImage:

    @staticmethod
    def get_terminal_capability():
        """
        Detects the best image protocol supported by the current environment.
        Returns: 'pixel' (iTerm/WezTerm), 'kitty' (Kitty), or 'ansi' (fallback).
        """
        if not sys.stdout.isatty():
            return "ascii" # stdout is not a TTY, so we can't reliably use advanced protocols. Fall back to ASCII art.

        env = {k: os.environ.get(k, "").lower() for k in ["TERM", "TERM_PROGRAM", "LC_TERMINAL"]}

        # 1. iTerm2 / WezTerm / Konsole (Modern versions support iTerm protocol)
        pixel_terms = ["iterm", "wezterm", "konsole", "iterm2", "iterm.app"]
        if any(t in env.values() for t in pixel_terms):
            return "pixel"

        # 2. Kitty (Uses its own Graphics Protocol)
        if "kitty" in env.values():
            return "kitty"

        # 3. Fallback for basic terminals (Linux TTY, basic SSH, old Windows)
        print("⚠️  No advanced terminal image protocol detected. Falling back to ANSI art (low quality).")
        for value in env.values():
            print(f"   Debug: Terminal env value: {value}")
        return "ansi"

    @staticmethod
    def display(image: Image.Image):
        capability = TerminalImage.get_terminal_capability()
        if capability == "pixel":
            imgcat(image) # iTerm2/WezTerm/Konsole support the iTerm protocol, so we can use imgcat directly
        elif capability == "kitty":
            imgcat(image) # Kitty protocol is supported by imgcat, so we can use it directly
        elif capability == "ansi":
            print(climage.convert_pil(image, is_unicode=True, width=80))
        else:
            print(f"⚠️  Unrecognized terminal capability {capability}. Unable to display image.")

    def _display_pixel(img: Image.Image):
        imgcat(img)

    def _display_kitty(img: Image.Image):
        imgcat(img)

    def _display_ansi(img: Image.Image):
        print(climage.convert_pil(img, is_unicode=True, width=80))
