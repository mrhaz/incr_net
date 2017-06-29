open Core.Std
open Import

(* CR hross: Need to change these to be optionally Incr.Var.t and Incr.t. *)
type contents_kind =
  | Float_vector of float Array.t
  | Incr_vector of float Incr.t Array.t
  | Incr_var_vector of float Incr.Var.t Array.t
  | Float_matrix of float Array.t Array.t
  | Incr_matrix of float Incr.t Array.t Array.t
  | Incr_var_matrix of float Incr.Var.t Array.t Array.t

type derivative_kind =
  | Deriv_vector of float Array.t
  | Deriv_matrix of float Array.t Array.t

type t = {
  kind       : [`Float | `Incr | `Incr_var];
  contents   : contents_kind;
  derivative : derivative_kind
} [@@deriving fields]

let var_to_incrs t =
  let contents =
    match t.contents with
    | Incr_var_vector vec -> Incr_vector (to_incrs vec)
    | Incr_var_matrix mat -> Incr_matrix (to_incrs' mat)
  in
  { kind = t.kind;
    contents;
    derivative = t.derivative
  }
;;

let length t =
  match t.contents with
  | Float_vector vec -> Array.length vec
  | Incr_vector vec -> Array.length vec
  | Incr_var_vector vec -> Array.length vec
  | Float_matrix mat -> Array.length mat
  | Incr_matrix mat -> Array.length mat
  | Incr_var_matrix mat -> Array.length mat
;;

let length' t =
  match t.contents with
  | Float_matrix mat -> Array.length (Array.get mat 0)
  | Incr_matrix mat -> Array.length (Array.get mat 0)
  | Incr_var_matrix mat -> Array.length (Array.get mat 0)
  | _ -> failwith "Input not a matrix"
;;


(* CR hross: Randomly initialise matrix entries. *)
let create kind ~dimx ?dimy () =
  let contents, derivative =
    let c, d =
      match dimx, dimy with
      | _, None ->
        begin
          let contents = Float_vector (Array.create ~len:dimx 1.) in
          let derivative = Deriv_vector (Array.create ~len:dimx 0.) in
          contents, derivative
        end
      | _, Some dimy ->
        begin
          let contents = Float_matrix (Array.make_matrix ~dimx ~dimy 1.) in
          let derivative = Deriv_matrix (Array.make_matrix ~dimx ~dimy 0.) in
          contents, derivative
        end
    in
    match kind, c with
    | `Incr, Float_vector vec -> Incr_vector (to_vars vec |> to_incrs), d
    | `Incr, Float_matrix mat -> Incr_matrix (to_vars' mat |> to_incrs'), d
    | `Incr_var, Float_vector vec -> Incr_var_vector (to_vars vec), d
    | `Incr_var, Float_matrix mat -> Incr_var_matrix (to_vars' mat), d
    | _, _ -> c, d
  in
  { kind;
    contents;
    derivative
  }
;;

let mat_vec_mul_backprop ~mat ~out ?vec ?observers () =
  let out_dw, mat_dw =
    match out.derivative, mat.derivative with
    | Deriv_vector vec_dw, Deriv_matrix mat_dw -> vec_dw, mat_dw
    | _, _ -> failwith "unreachable"
  in
  match mat.contents, out.contents with
  | Float_matrix _, Float_vector _->
    begin
      let vec =
        match vec with
        | Some vec ->
          begin
            match vec.contents with
            | Float_vector vec -> vec
            | _ -> failwith "blah"
          end
        | _ -> failwith "Failed to match vector"
      in
      for i = 0 to Array.length mat_dw do
        let column = Array.get mat_dw i in
        let b = Array.get out_dw i in
        for k = 0 to Array.length column do
          let cur_sum = Array.get column k in
          let vec_k = Array.get vec k in
          Array.set column k (cur_sum +. vec_k *. b)
        done
      done
    end
  | Incr_matrix _, Incr_vector _ ->
    begin
      let observers =
        match observers with
        | None -> failwith "must specify observers"
        | Some observers -> observers
      in
      for i = 0 to (Array.length mat_dw - 1) do
        let column = Array.get mat_dw i in
        let b = Array.get out_dw i in
        for k = 0 to (Array.length column - 1) do
          let cur_sum = Array.get column k in
          let observer_k = Array.get observers k |> Incr.Observer.value_exn in
          Array.set column k (cur_sum +. observer_k *. b)
          done
      done
    end
  | _, _ -> failwith "Can't perform backprop for this matrix type"
;;

let relu ~vec =
  let f = Float.max 0. in
  let float_relu = Array.map ~f in
  let incr_relu = Array.map ~f:(Incr.map ~f) in
  let contents =
    match vec.contents with
    | Float_vector vec -> Float_vector (float_relu vec)
    | Incr_vector vec -> Incr_vector (incr_relu vec)
  in
  let out_t =
    { kind = vec.kind;
      contents;
      derivative = Deriv_vector (Array.create ~len:(length vec) 0.)
    }
  in
  out_t
;;

(* Takes a weights matrix and applies it to the input incrs. *)
let mat_vec_mul ~mat ~vec =
  let float_dot_product vec1 vec2 =
    Array.map2_exn vec1 vec2 ~f:( *.)
    |> Array.fold ~init:0. ~f:(+.)
  in
  let float_matmul mat vec =
    Array.map mat ~f:(float_dot_product vec)
  in
  let incr_dot_product vec1 vec2 =
    Array.map2_exn vec1 vec2 ~f:(Incr.map2 ~f:( *.))
    |> Incr.sum ~zero:0. ~add:(+.) ~sub:(-.)
  in
  let incr_matmul mat vec =
    Array.map mat ~f:(incr_dot_product vec)
  in
  let contents =
    match mat.contents, vec.contents with
    | Float_matrix mat, Float_vector vec -> Float_vector (float_matmul mat vec)
    | Incr_matrix mat, Incr_vector vec -> Incr_vector (incr_matmul mat vec)
    | _, _ -> failwith "Cannot multiply nn_matrices of different types (or nn var matrices)"
  in
  let out_t = {
    kind = vec.kind;
    contents;
    derivative = Deriv_vector (Array.create ~len:(length vec) 0.)
  }
  in
  let vec, observers  =
    match vec.contents with
    | Float_vector _ -> Some vec, None
    | Incr_vector vec -> None, Some (Array.map vec ~f:Incr.observe)
  in
  (out_t, mat_vec_mul_backprop ~mat ~out:out_t ?vec ?observers)
;;

(* Returns an array containing the next training example.
 *
 * For this contrived example, we simple "snake" a line across
 * the image as the iterations increase.
 * *)
let fill_in_place_next_training_example ~vec ~iter =
  incr iter;
  let input_dim = length vec in
  let fill_line image =
    let offset = !iter % input_dim in
    let dim = sqrt (Int.to_float input_dim) |> Float.to_int in
    for i = offset to Int.min ((Array.length image) - 1) (offset + dim) do
      Array.set image i 2.;
    done;
    image
  in
  let raw_image =
    Array.create ~len:input_dim 0.
    |> fill_line
  in
  match vec.contents with
  | Float_vector vec -> Array.iteri vec ~f:(fun i elt ->
      Array.set vec i (Array.get raw_image i))
  | Incr_var_vector vec -> Array.iter2_exn vec raw_image ~f:Incr.Var.set
  | _ -> failwith "Can't fill input nn_matrix with next example"
;;
