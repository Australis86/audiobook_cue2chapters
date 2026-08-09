#!/usr/bin/env bash
#
# Dependencies:
#   bash 4+ (arrays and mapfile)
#   shntool
#   flac
#   ffmpeg
#   cuetools (optional; uses cuetag to fetch metadata from the CUE sheet)
#
# Copyright 2026 Joshua White
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

usage="$(basename "$0") [-h] input_file(s) -- script to split a CUE+FLAC or CUE+WAV audiobook CD image and into chapters

where:
    -h  show this help text
    -b  target MP3 bitrate in kbps (default 192)
    -g  set a custom genre (default is 'Audiobook' if no metadata)
    -d  set working directory (default is location of CUE file)
    -a  append prologue and epilogue to adjacent chapters
    -i  keep intermediate files
    -o  overwrite existing file
    -v  enabled verbose (debugging) output

Files are output to a subdirectory of the working directory, e.g. [CUE NAME]/[CHAPTERS]"

# SETTINGS

# Make string comparision case-insensitive
shopt -s nocasematch


# GLOBALS

EXIT_CODE=0
VERBOSE=false
BITRATE=192
GENRE="Audiobook"
WORKING_DIR=""
OVERWRITE=false
INTERMEDIATE=false
APPEND_PROLOGUE=false


# TEMPORARY WORKSPACE

AUDIO_FILE=""
AUDIO_FORMAT="wav"


# FUNCTIONS

function check_cue() {
    cuefilepath=$1
    cuedir=$2

    # Determine the source file referenced by the CUE sheet
    cuesrcfile=`grep -m1 "FILE" "$cuefilepath" | awk '{NF--;$1=$1;sub(".*"$2,$2,$0)}1' | tr -d '"'`
    srcpath="$cuedir/$cuesrcfile"

    if [ ! -f "$srcpath" ]; then
        echo "Source audio file referenced by cue sheet is missing. Unable to proceed."
        return 66
    fi

    if $VERBOSE; then echo "CUE audio: $srcpath"; fi

    # Check file type
    ftype=`file -b "$srcpath"`
    if $VERBOSE; then echo "  $ftype"; fi

    # See http://shnutils.freeshell.org/shntool/ for list of supported formats
    # In this case we're only going to work with FLAC and WAVE (lossless)
    if [[ "$ftype" =~ "FLAC audio" ]]; then
        AUDIO_FILE=$srcpath
        AUDIO_FORMAT='flac'
        return 0 # "True" case / valid format
    elif [[ "$ftype" =~ "WAVE audio" ]]; then
        AUDIO_FILE=$srcpath
        AUDIO_FORMAT='wav'
        return 0 # "True" case / valid format
    else
        AUDIO_FILE=""
        return 1 # "False" case / unsupported format
    fi
}


function split_cue() {
    cuefilepath=$1
    workingdir=$2

    cuename=`basename "$cuefilepath"`
    outdir="$workingdir/${cuename%.*}"
    outdir_split="$outdir/split"
    outdir_concat="$outdir/concat"
    mkdir -p "$outdir_split"
    mkdir -p "$outdir_concat"

    echo "Processing $cuename ..."

    if $VERBOSE; then echo "Writing output files to $outdir_split/"; fi

    files=$(shopt -s nullglob dotglob; echo "${outdir_split}"*)
    if (( ${#files} )) && [ $OVERWRITE == "false" ]; then
        echo "ERROR: Output directory already contains files; aborting"
        return 1
    else
        # To avoid issues with combining chapters, remove matching files first
        echo "Removing previous extracted tracks to avoid conflicts when merging ..."
        rm -f "$outdir_split/"*."$AUDIO_FORMAT"
        rm -f "$outdir_concat/"*."$AUDIO_FORMAT"
        rm -f "$outdir/"*.mp3

        # Use shntool to split the cue file into tracks
        if $VERBOSE; then
            shntool split -f "$cuefilepath" -o $AUDIO_FORMAT -t "%n %t" -O always "$AUDIO_FILE" -d "$outdir_split"
        else
            echo "Splitting CUE into tracks ..."
            shntool split -q -f "$cuefilepath" -o $AUDIO_FORMAT -t "%n %t" -O always "$AUDIO_FILE" -d "$outdir_split"
        fi
        ec=$?

        if [ $ec -ne 0 ]; then
            echo "Splitting failed. Please examine output folder and clean up any intermediate files."
            return 67
        fi

        # If cuetag is available, copy metadata from original cue to new tracks
        # This doesn't parse all comments in CUE files, nor any metadata stored in the audio file itself
        if command -v cuetag >/dev/null 2>&1; then
            cuetag "$cuefilepath" "$outdir_split/"*."$AUDIO_FORMAT"
        fi

        # For FLAC files, copy any available metadata from the original disc image to the split tracks
        # CD rippers such as CUETools/CUERipper or Exact Audio Copy usually populate some metadata fields
        if [[ $AUDIO_FORMAT = "flac" ]]; then
            t1_data="$(mktemp)"
            flac_data="$(mktemp)"

            # Note: LOG and COMMENT tags are excluded since multi-line tags break metaflac

            # Get any pre-existing tags (e.g. provided by cuetag)
            metaflac --no-utf8-convert --export-tags-to="$t1_data" --remove-tag=LOG --remove-tag=COMMENT "$outdir_split/01"*."$AUDIO_FORMAT"

            # Export album-wide tags
            metaflac --no-utf8-convert --export-tags-to="$flac_data" --remove-tag=LOG --remove-tag=COMMENT "$AUDIO_FILE"

            # Iterate through pre-existing tags, get the tag names
            # and remove the matching lines from the album tag export
            while read tag; do
                tagname=`echo $tag | cut -d '=' -f 1`
                sed -i "/^$tagname=/d" $flac_data
            done < $t1_data

            genre_set=$(grep '^GENRE' $flac_data)
            if [ -z "$genre_set" ]; then
                # Genre tag currently not specified
                echo "GENRE=$GENRE" >> $flac_data
            fi

            # Import album-wide tags from temporary file
            # This should not overwrite existing tags or append to them
            metaflac --import-tags-from="$flac_data" "$outdir_split/"*."$AUDIO_FORMAT"
        fi

        # Chapter-matching and concatenation logic heavily based on
        # https://github.com/xmutantson/audiobook_chapter_merger

        # Identify all source files
        mapfile -t src_audio < <(find "$outdir_split" -type f -iname '*.'$AUDIO_FORMAT | sort)

        # Iterate through them and try to match against chapter/episode/part
        declare -A chapter_arr

        # Regex to match parts
        # This should match "02 Chapter One", "02 - Part 1", "02 Episode 1", etc.
        segment_regex_main='^[0-9]+[[:space:]]+(Chapter|Episode|Part)[[:space:]]+(One|Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten|[0-9]+)'
        
        # Regex for extras such as music, behind-the-scenes and interviews
        segment_regex_extras='^[0-9]+[[:space:]]+(Music|Interviews).*(One|Two|Three|Four|Five|Six|Seven|Eight|Nine|Ten|[0-9]+)'

        declare -i segment_counter=0
        segment_tracker=""
        prepend_segment=""

        for filepath in "${src_audio[@]}"; do
            fullpath="$(realpath "$filepath")"
            filename="$(basename "$filepath")"
            name_no_ext="${filename%.*}"

            if [[ $name_no_ext =~ $segment_regex_main || $name_no_ext =~ $segment_regex_extras ]]; then
                prefix="${BASH_REMATCH[1]}"             # segment type

                # Distinguish between chapters/episodes/parts and extras, which are usually standalone
                if [[ $name_no_ext =~ $segment_regex_main ]]; then
                    segment_number="${BASH_REMATCH[2]}"     # match group corresponding to chapter/part/episode number
                    segment_name="$prefix $segment_number"  # create the segment name
                else
                    segment_name="$prefix"                  # create the segment name
                fi

                if [[ "$segment_tracker" != "$segment_name" ]]; then
                    segment_tracker=$segment_name
                    segment_counter+=1
                fi

                # Append the full file path to the corresponding list
                # Relative paths seem to mess with ffmpeg concatenation
                arr_index=$(printf "%02d %s" $segment_counter "$segment_name")

                if [[ "$prepend_segment" != "" ]]; then
                    chapter_arr["$arr_index"]+="$prepend_segment|"
                    prepend_segment=""
                fi

                chapter_arr["$arr_index"]+="$fullpath|"

                if $VERBOSE; then echo "($segment_counter) $filename --> $arr_index.$AUDIO_FORMAT"; fi
            else
                if $APPEND_PROLOGUE && [[ $name_no_ext =~ 'prologue' || $name_no_ext =~ 'epilogue' ]]; then
                    # Check for prologue and epilogue
                    if [[ $name_no_ext =~ "prologue" ]]; then
                        # Save full path to local variable to be added to chapter_arr on next iteration
                        prepend_segment=$fullpath

                        if $VERBOSE; then echo "($segment_counter) $filename held over to next chaper"; fi
                    elif [[ $name_no_ext =~ "epilogue" ]]; then
                        # For the epilogue, append it to the chapter_arr using the last-known value for arr_index
                        chapter_arr["$arr_index"]+="$fullpath|"

                        if $VERBOSE; then echo "($segment_counter) $filename --> $arr_index.$AUDIO_FORMAT"; fi
                    fi
                else
                    segment_counter+=1
                    file_num=$(printf "%02d" $segment_counter)
                    newname=$(echo $filename | sed "s/^[0-9]\+/$file_num/g")

                    if $VERBOSE; then echo "($segment_counter) $filename --> $newname"; fi

                    # Copy and rename individual file
                    cp "$filepath" "$outdir_concat/$newname"

                    if [[ $AUDIO_FORMAT = "flac" ]]; then
                        # Update track number in metadata
                        metaflac --remove-tag=TRACKNUMBER --set-tag="TRACKNUMBER=$segment_counter" "$outdir_concat/$newname"
                    fi

                fi
            fi
        done

        # Concatenate segments
        echo "Concatenating ..."
        for chapter in "${!chapter_arr[@]}"; do
            file_list="${chapter_arr[$chapter]}"
            file_list="${file_list%|}"  # Remove trailing '|'

            # Create a temporary file (usually in /tmp)
            tmp_list="$(mktemp)"

            IFS='|' read -r -a parts <<< "$file_list"
            for f in "${parts[@]}"; do
                # Escape single quotes in filenames
                esc_f="${f//\'/\'\\\'\'}"
                echo "file '$esc_f'" >> "$tmp_list"
            done

            # Generate the output filename (Episode Two.flac, Chapter 1.wav, etc.)
            out_filename="${chapter}.$AUDIO_FORMAT"
            out_filepath="$outdir_concat/$out_filename"

            if $VERBOSE; then echo "  $out_filename"; fi

            # Create intermediate FLAC/WAV files
            # Note: there is a known bug (https://trac.ffmpeg.org/ticket/10379)
            # where setting -c copy on FLAC files produces an output file with
            # the duration set to the length of the first file. This forces
            # us to re-encode to ensure the output file duration is correct.
            </dev/null ffmpeg -hide_banner -loglevel error -f concat -safe 0 -i "$tmp_list" -c:a $AUDIO_FORMAT -y "$out_filepath"

            if [[ $AUDIO_FORMAT = "flac" ]]; then
                # Copy tags from the first source file in the concatenation list
                metaflac --no-utf8-convert --export-tags-to=- "${parts[0]}" | metaflac --import-tags-from=- "$out_filepath"

                # Update the track number and title
                track_num=$(echo $chapter | cut -d ' ' -f 1 | sed 's/^0*//')
                track_title=$(echo $chapter | cut -d ' ' -f 2-)
                metaflac --remove-tag=TITLE --remove-tag=TRACKNUMBER --set-tag="TITLE=$track_title" --set-tag="TRACKNUMBER=$track_num" "$out_filepath"
            fi
        done

        # Iterate through all the *.$AUDIO_FORMAT files in $outdir_concat and convert to MP3
        mapfile -t prepared_audio < <(find "$outdir_concat" -type f -iname '*.'$AUDIO_FORMAT | sort)

        echo "Converting to MP3 ..."
        for filepath in "${prepared_audio[@]}"; do
            fullpath="$(realpath "$filepath")"
            filename="$(basename "$filepath")"
            name_no_ext="${filename%.*}"

            # Convert to MP3
            if $VERBOSE; then echo "  $name_no_ext.mp3"; fi
            </dev/null ffmpeg -y -loglevel error -i "$fullpath" -codec:a libmp3lame -ab ${BITRATE}k "$outdir/$name_no_ext.mp3"
        done

        # Clean up
        if [ $INTERMEDIATE == "false" ]; then
            echo "Removing intermediate files ..."
            rm -rf "$outdir_split"
            rm -rf "$outdir_concat"
        fi
    fi
}


# CLI

while getopts ':hb:g:d:aiov' option; do
  case "$option" in
    h) echo "$usage"
       exit
       ;;
    b) BITRATE=$OPTARG
       ;;
    g) GENRE=$OPTARG
       ;;
    d) WORKING_DIR=$OPTARG
       ;;
    a) APPEND_PROLOGUE=true
       ;;
    i) INTERMEDIATE=true
       ;;
    o) OVERWRITE=true
       ;;
    v) VERBOSE=true
       ;;
   \?) printf "illegal option: -%s\n" "$OPTARG" >&2
       echo "$usage" >&2
       exit 1
       ;;
  esac
done

shift $((OPTIND - 1))

# Error handling (check input)
if [ $# -eq 0 ]; then
    echo "Error: No input files specified" >&2
    usage
fi


# MAIN

if $VERBOSE; then echo "MP3 encoding bitrate set to ${BITRATE}kbps"; fi

# Iterate through all files provided
for file in "$@"; do
    if [ ! -f "$file" ]; then
        echo "Warning: '$file' not found, skipping" >&2
        if [ $EXIT_CODE -eq 0 ]; then EXIT_CODE=66; fi
        continue
    fi

    if $VERBOSE; then echo "CUE sheet: $file"; fi

    # Get the path to the CUE file
    cuedir=`dirname "$file"`

    if [ -z "$WORKING_DIR" ]; then
        WORKING_DIR=$cuedir
    fi

    # Check source file format
    if check_cue "$file" "$cuedir"; then
        split_cue "$file" "$WORKING_DIR"
        ec=$?
        if [ $EXIT_CODE -eq 0 ]; then EXIT_CODE=$ec; fi
    else
        if [ $EXIT_CODE -eq 0 ]; then EXIT_CODE=65; fi
    fi
done

exit $EXIT_CODE
