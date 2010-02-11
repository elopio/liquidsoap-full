(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2009 Savonet team

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

(** Outputs using the FAAC encoder for AAC. *)

(* TODO: merge with main file output class. *)

open Source
open Dtools
open Faac

let create_encoder ~bandwidth ~bitrate ~quality =
  let enc, faac_samples, faac_buflen = Faac.create 44100 2 in
    (* Output settings *)
    Faac.set_configuration enc
      ~mpeg_version:4 ~quality:quality ~bitrate:bitrate ~bandwidth:bandwidth ();
    enc, faac_samples, faac_buflen

(** Output in an AAC file *)

class to_file
  ~infallible ~on_stop ~on_start
  ~filename ~bandwidth ~bitrate ~quality ~autostart source =
object (self)
  inherit
    Output.encoded 
       ~infallible ~on_stop ~on_start
       ~name:filename ~kind:"output.file.aac" ~autostart source

  val mutable faac_buflen = 0

  val mutable encoder : Faac.t option = None

  method reset_encoder m = ""

  method encode frame start len =
    let e = Utils.get_some encoder in
    let b = AFrame.get_float_pcm frame in
    let start = Fmt.samples_of_ticks start in
    let len = Fmt.samples_of_ticks len in
    let outbuf = String.create faac_buflen in
    let n = Faac.encode_ni e b start len outbuf 0 in
      String.sub outbuf 0 n ;

  val mutable fd = None

  method output_start =
    assert (fd = None) ;
    let enc, samples, buflen = create_encoder ~quality ~bitrate ~bandwidth in
      faac_buflen <- buflen ;
      fd <- Some (open_out filename) ;
      encoder <- Some enc

  method output_stop =
    match fd with
      | None -> assert false
      | Some v -> close_out v ; fd <- None

  method send b =
    match fd with
      | None -> assert false
      | Some fd -> output_string fd b

  method output_reset = ()
end

let () =
  Lang.add_operator "output.file.aac"
   ( Output.proto @
    [ "bandwidth",
      Lang.int_t,
      Some (Lang.int 16000),
      None ;

      "bitrate",
      Lang.int_t,
      Some (Lang.int 128),
      None ;

      "quality",
      Lang.int_t,
      Some (Lang.int 100),
      None ;

      "",
      Lang.string_t,
      None,
      Some "Filename where to output the AAC stream." ;

      "", Lang.source_t, None, None ])
    ~category:Lang.Output
    ~descr:"Output the source's stream as an AAC file."
    (fun p _ ->
       let e f v = f (List.assoc v p) in
       let quality = e Lang.to_int "quality" in
       let bandwidth = e Lang.to_int "bandwidth" in
       let bitrate = e Lang.to_int "bitrate" in
       let filename = Lang.to_string (Lang.assoc "" 1 p) in
       let infallible = not (Lang.to_bool (List.assoc "fallible" p)) in
       let autostart = e Lang.to_bool "start" in
       let on_start =
         let f = List.assoc "on_start" p in
           fun () -> ignore (Lang.apply f [])
       in
       let on_stop =
         let f = List.assoc "on_stop" p in
           fun () -> ignore (Lang.apply f [])
       in
       let source = Lang.assoc "" 2 p in
         ((new to_file ~filename ~infallible ~on_stop ~on_start
             ~quality ~bitrate ~bandwidth ~autostart source):>source))