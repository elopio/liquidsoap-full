(*****************************************************************************

  Liquidsoap, a programmable stream generator.
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

type data =
  (int, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t
type t =
  {
    (** Order matter for C callbacks !! *)
    data   : data;
    width  : int;
    height : int;
    stride : int
  }

type color = int * int * int * int

let rgb_of_int n =
  if n > 0xffffff then raise (Invalid_argument "Not a color");
  (n lsr 16) land 0xff, (n lsr 8) land 0xff, n land 0xff

let create ?stride width height =
  let stride =
    match stride with
      | Some v -> v
      | None -> 4*width
  in
  let data =
    Bigarray.Array1.create
     Bigarray.int8_unsigned Bigarray.c_layout
     (stride*height)
  in
  {
    data   = data;
    width  = width;
    height = height;
    stride = stride
  }

let copy f =
  let nf = create ~stride:f.stride f.width f.height in
  Bigarray.Array1.blit f.data nf.data;
  nf

let copy_channel a = Array.map copy a

external blit : t -> t -> unit = "caml_rgb_blit" "noalloc"

external blit_off : t -> t -> int -> int -> bool -> unit
  = "caml_rgb_blit_off" "noalloc"

external blit_off_scale : t -> t -> int * int -> int * int -> bool -> unit
  = "caml_rgb_blit_off_scale" "noalloc"

let blit_fast src dst =
  blit src dst

let blit ?(blank=true) ?(x=0) ?(y=0) ?w ?h src dst =
  match (w,h) with
    | None, None -> blit_off src dst x y blank
    | Some w, Some h -> blit_off_scale src dst (x,y) (w,h) blank
    | _, _ -> assert false

external fill : t -> color -> unit = "caml_rgb_fill" "noalloc"

external blank : t -> unit = "caml_rgb_blank" "noalloc"

external of_linear_rgb : t -> string -> unit
  = "caml_rgb_of_linear_rgb" "noalloc"

let of_linear_rgb data width =
  let height = (String.length data / 3) / width in
  let ans = create width height in
    of_linear_rgb ans data;
    ans

type yuv = (data *int ) * (data * data * int)

external of_YUV420 : yuv -> t -> unit = "caml_rgb_of_YUV420" "noalloc"

let of_YUV420_create frame width height =
  let ans = create width height in
    of_YUV420 frame ans;
    ans

external create_yuv : int -> int -> yuv = "caml_yuv_create"

external blank_yuv : yuv -> unit = "caml_yuv_blank"

external to_YUV420 : t -> yuv -> unit = "caml_rgb_to_YUV420" "noalloc"

external get_pixel : t -> int -> int -> color = "caml_rgb_get_pixel"

external set_pixel : t -> int -> int -> color -> unit
  = "caml_rgb_set_pixel" "noalloc"

external randomize : t -> unit = "caml_rgb_randomize" "noalloc"

external scale_coef : t -> t -> int * int -> int * int -> unit
  = "caml_rgb_scale" "noalloc"

external bilinear_scale_coef : t -> t -> float -> float -> unit
  = "caml_rgb_bilinear_scale" "noalloc"

let scale src dst =
  let sw, sh = src.width,src.height in
  let dw, dh = dst.width,dst.height in
    scale_coef dst src (dw, sw) (dh, sh)

let scale_to src w h =
  let sw, sh = src.width,src.height in
  let dst = create w h in
    scale_coef dst src (w, sw) (h, sh);
    dst

let proportional_scale ?(bilinear=false) dst src =
  let sw, sh = src.width,src.height in
  let dw, dh = dst.width,dst.height in
  let n, d =
    if dh * sw < sh * dw then
      dh, sh
    else
      dw, sw
  in
    if bilinear then
      let a = float_of_int n /. float_of_int d in
        bilinear_scale_coef dst src a a
    else
      scale_coef dst src (n, d) (n, d)

let proportional_scale_to ?(bilinear=false) src w h =
  let dst = create w h in
    proportional_scale ~bilinear dst src;
    dst

external to_bmp : t -> string = "caml_rgb_to_bmp"

let save_bmp f fname =
  let oc = open_out_bin fname in
    output_string oc (to_bmp f);
    close_out oc

exception Invalid_format of string

let ppm_header =
  Str.regexp "P6\n\\(#.*\n\\)?\\([0-9]+\\) \\([0-9]+\\)\n\\([0-9]+\\)\n"

let of_ppm ?alpha data =
  (
    try
      if not (Str.string_partial_match ppm_header data 0) then
        raise (Invalid_format "Not a PPM file.");
    with
      | _ -> raise (Invalid_format "Not a PPM file.")
  );
  let w = int_of_string (Str.matched_group 2 data) in
  let h = int_of_string (Str.matched_group 3 data) in
  let d = int_of_string (Str.matched_group 4 data) in
  let o = Str.match_end () in
  let datalen = String.length data - o in
    if d <> 255 then
      raise (Invalid_format (Printf.sprintf "Files of color depth %d \
                                             are not handled." d));
    if datalen < 3*w*h then
      raise (Invalid_format (Printf.sprintf "Got %d bytes of data instead of \
                                             expected %d." datalen (3*w*h)));
    let ans = create w h in
      for j = 0 to h - 1 do
        for i = 0 to w - 1 do
          let r, g, b =
            int_of_char data.[o + 3 * (j * w + i) + 0],
            int_of_char data.[o + 3 * (j * w + i) + 1],
            int_of_char data.[o + 3 * (j * w + i) + 2]
          in
          let a =
            match alpha with
              | Some (ra, ga, ba) ->
                  if r = ra && g = ga && b = ba then 0x00 else 0xff
              | None -> 0xff
          in
            set_pixel ans i j (r, g, b, a);
        done
      done;
      ans

let read_ppm ?alpha fname =
  let ic = open_in_bin fname in
  let len = in_channel_length ic in
  let data = String.create len in
    really_input ic data 0 len;
    close_in ic;
    of_ppm ?alpha data

external to_int_image : t -> int array array = "caml_rgb_to_color_array"

external greyscale : t -> bool -> unit = "caml_rgb_greyscale" "noalloc"

let sepia buf = greyscale buf true

let greyscale buf = greyscale buf false

external invert : t -> unit = "caml_rgb_invert" "noalloc"

external add : t -> t -> unit = "caml_rgb_add" "noalloc"

external rotate : t -> float -> unit = "caml_rgb_rotate" "noalloc"

external scale_opacity : t -> float -> unit = "caml_rgb_scale_opacity" "noalloc"

external disk_opacity : t -> int -> int -> int -> unit
  = "caml_rgb_disk_opacity" "noalloc"

external affine : t -> float -> float -> int -> int -> unit
  = "caml_rgb_affine" "noalloc"

(* TODO: faster implementation? *)
let translate f x y =
  affine f 1. 1. x y

external mask : t -> t -> unit = "caml_rgb_mask" "noalloc"

external lomo : t -> unit = "caml_rgb_lomo" "noalloc"

external color_to_alpha : t -> int * int * int -> int -> unit
  = "caml_rgb_color_to_alpha" "noalloc"

external blur_alpha : t -> unit = "caml_rgb_blur_alpha"