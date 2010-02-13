(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2010 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

open Source

let chan = 0

let note_of_string = function
  | "-" -> -1 (* mute *)
  | "A" -> 69
  | "A#" | "Bb" -> 70
  | "B" | "Cb" -> 71
  | "C" | "B#" -> 72
  | "C#" | "Db" -> 73
  | "D" -> 74
  | "D#" | "Eb" -> 75
  | "E" | "Fb" -> 76
  | "F" | "E#" -> 77
  | "F#" | "Gb" -> 78
  | "G" -> 79
  | "G#" | "Ab" -> 80
  | _ -> assert false
let note_of_string s = note_of_string s - 12

class chord ~kind metadata_name (source:source) =
object (self)
  inherit operator kind [source] as super

  method stype = source#stype

  method remaining = source#remaining

  method is_ready = source#is_ready

  method abort_track = source#abort_track

  val mutable notes_on = []

  method private get_frame buf =
    let offset = MFrame.position buf in
    let moffset = Frame.position buf in
    source#get buf;
    let m = Frame.content_of_type buf moffset (Frame.type_of_kind kind) in
    let m = m.Frame.midi in
    let meta = MFrame.get_all_metadata buf in
    let chords =
      let ans = ref [] in
        List.iter
          (fun (t,m) ->
             if t >= offset then
               List.iter
                 (fun c ->
                    try
                      let sub = Pcre.exec ~pat:"^([A-G-](?:b|#)?)(|M|m|M7|m7|dim)$" c in
                      let n = Pcre.get_substring sub 1 in
                      let n = note_of_string n in
                      let m = Pcre.get_substring sub 2 in
                        ans := (t,n,m) :: !ans
                    with
                      | Not_found ->
                          self#log#f 3 "Could not parse chord '%s'." c
                 ) (Hashtbl.find_all m metadata_name)
          ) meta;
        List.rev !ans
    in
    let play t n =
      let notes = List.map (fun n -> t, Midi.Note_on (n,1.)) n in
        m.(chan) := notes @ !(m.(chan));
        notes_on <- n @ notes_on
    in
    let to_mute = ref [] in
    let mute t =
      let notes = List.map (fun n -> t, Midi.Note_off (n,1.)) notes_on in
        to_mute := notes @ !to_mute;
        notes_on <- []
    in
      List.iter
        (fun (t,c,m) -> (* time, base, mode *)
           mute t;
           (* Negative base note means mute. *)
           if c >= 0 then
             (
               match m with
                 | "" | "M" -> (* major *)
                     play t [c;c+4;c+7]
                 | "m" -> (* minor *)
                     play t [c;c+3;c+7]
                 | "7" ->
                     play t [c;c+4;c+7;c+10]
                 | "M7" ->
                     play t [c;c+4;c+7;c+11]
                 | "m7" ->
                     play t [c;c+3;c+7;c+10]
                 | "dim" ->
                     play t [c;c+3;c+6]
                 | m ->
                     self#log#f 5 "Unknown mode: %s\n%!" m
             );
        ) chords;
      (* We should mute before playing the new chord, so we need a stable sort. *)
      m.(chan) := Mutils.sort_track (!to_mute @ !(m.(chan)))
end

let () =
  (* TODO: is this really the type we want to give to it? *)
  let in_k = Lang.kind_type_of_kind_format ~fresh:1 Lang.any_fixed in
  let out_k = Lang.kind_type_of_kind_format ~fresh:1 (Lang.any_fixed_with ~midi:1 ()) in
  Lang.add_operator "midi.chord"
    [
      "metadata", Lang.string_t, Some (Lang.string "chord"), Some "Name of the metadata containing the chords.";
      "", Lang.source_t in_k, None, None
    ]
    ~kind:(Lang.Unconstrained out_k)
    ~category:Lang.MIDIProcessing
    ~descr:"Generate a chord."
    (fun p kind ->
       let f v = List.assoc v p in
       let src = Lang.to_source (f "") in
       let metadata = Lang.to_string (f "metadata") in
         new chord ~kind metadata src)
