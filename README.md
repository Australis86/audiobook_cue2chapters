# audiobook_cue2chapters
Split a CUE+FLAC or CUE+WAV audiobook CD image into chapters

## Background

This script was written to solve a very specific problem: to extract 
the chapters/episodes from a CD image (i.e. a CUE+WAV or CUE+FLAC) of 
an audiobook, audio drama or radio play and ensure that all the tracks
for each chapter/episode were combined but individual chapters/episodes 
were not. It could then optionally convert each chapter/episode to MP3 
for use with an MP3 player.

It was inspired by these scripts:

- https://github.com/xmutantson/audiobook_chapter_merger
- https://github.com/lucvanbraekel/split_flac

No LLMs were used in the creation of this script.


## Dependencies

- bash 4+
- shntool
- flac
- ffmpeg
- cuetools (optional; uses cuetag to fetch metadata from the CUE sheet)


## Usage

The script takes a single CUE file as its input argument with several 
optional parameters:

| parameter | example | description |
| --- | --- | --- |
| -b | 128 | target MP3 bitrate in kbps (default 192) |
| -g | "Audio Theatre" | Set a custom genre (default is "Audiobook") |
| -a | | Boolean flag to append the prologue and epilogue to the adjacent chapter (useful for gapless audio dramas where these connect to opening or closing titles/themes) |
| -i | | Boolean flag to preserve intermediate files (default is to automatically clean up) |
| -o | | Boolean flag to enable overwriting existing files |
| -v | | Boolean flag to enable verbose output |

Files are output to a subdirectory relative to the provided CUE file, e.g. [CUE NAME]/[CHAPTERS]


## Metadata (CUE+FLAC disc images only)

If the cuetools package is present, cuetags will be used to try to 
populate the individual tracks with metadata from the CUE sheet. 

Additionally, if the disc image already has album/disc data populated 
by the CD ripper (e.g. CUETools, EAC, etc.), this will also be used.

Metadata for CUE+WAV disc images are currently not supported.


# Copyright and Licence

Unless otherwise stated, these scripts are Copyright © Joshua White and 
licensed under the GNU GPL v3.0.


