type cls = Kw | Kl | Ks | Kd
type op_base =
  | Oadd
  | Osub
  | Omul
type op = cls * op_base

let commutative = function
  | (_, (Oadd | Omul)) -> true
  | (_, _) -> false

let associative = function
  | (_, (Oadd | Omul)) -> true
  | (_, _) -> false

type atomic_pattern =
  | Tmp
  | AnyCon
  | Con of int64

type pattern =
  | Bnr of op * pattern * pattern
  | Atm of atomic_pattern
  | Var of string * atomic_pattern

let is_atomic = function
  | (Atm _ | Var _) -> true
  | _ -> false

let show_op (k, o) =
  (match o with
   | Oadd -> "add"
   | Osub -> "sub"
   | Omul -> "mul") ^
  (match k with
   | Kw -> "w"
   | Kl -> "l"
   | Ks -> "s"
   | Kd -> "d")

let rec show_pattern p =
  match p with
  | Atm Tmp -> "%"
  | Atm AnyCon -> "$"
  | Atm (Con n) -> Int64.to_string n
  | Var (v, p) ->
      show_pattern (Atm p) ^ "'" ^ v
  | Bnr (o, pl, pr) ->
      "(" ^ show_op o ^
      " " ^ show_pattern pl ^
      " " ^ show_pattern pr ^ ")"

let rec pattern_match p w =
  match p with
  | Var (_, p) ->
      pattern_match (Atm p) w
  | Atm Tmp ->
      begin match w with
      | Atm (Con _ | AnyCon) -> false
      | _ -> true
      end
  | Atm (Con _) -> w = p
  | Atm (AnyCon) ->
      not (pattern_match (Atm Tmp) w)
  | Bnr (o, pl, pr) ->
      begin match w with
      | Bnr (o', wl, wr) ->
          o' = o &&
          pattern_match pl wl &&
          pattern_match pr wr
      | _ -> false
      end

type 'a cursor = (* a position inside a pattern *)
  | Bnrl of op * 'a cursor * pattern
  | Bnrr of op * pattern * 'a cursor
  | Top of 'a

let rec fold_cursor c p =
  match c with
  | Bnrl (o, c', p') -> fold_cursor c' (Bnr (o, p, p'))
  | Bnrr (o, p', c') -> fold_cursor c' (Bnr (o, p', p))
  | Top _ -> p

let peel p x =
  let once out (p, c) =
    match p with
    | Var (_, p) -> (Atm p, c) :: out
    | Atm _ -> (p, c) :: out
    | Bnr (o, pl, pr) ->
        (pl, Bnrl (o, c, pr)) ::
        (pr, Bnrr (o, pl, c)) :: out
  in
  let rec go l =
    let l' = List.fold_left once [] l in
    if List.length l' = List.length l
    then l'
    else go l'
  in go [(p, Top x)]

let fold_pairs l1 l2 ini f =
  let rec go acc = function
    | [] -> acc
    | a :: l1' ->
        go (List.fold_left
          (fun acc b -> f (a, b) acc)
          acc l2) l1'
  in go ini l1

let iter_pairs l f =
  fold_pairs l l () (fun x () -> f x)

type 'a state =
  { id: int
  ; seen: pattern
  ; point: ('a cursor) list }

let rec binops side {point; _} =
  List.filter_map (fun c ->
      match c, side with
      | Bnrl (o, c, r), `L -> Some ((o, c), r)
      | Bnrr (o, l, c), `R -> Some ((o, c), l)
      | _ -> None)
    point

let group_by_fst l =
  List.fast_sort (fun (a, _) (b, _) ->
    compare a b) l |>
  List.fold_left (fun (oo, l, res) (o', c) ->
      match oo with
      | None -> (Some o', [c], [])
      | Some o when o = o' -> (oo, c :: l, res)
      | Some o -> (Some o', [c], (o, l) :: res))
    (None, [], []) |>
  (function
    | (None, _, _) -> []
    | (Some o, l, res) -> (o, l) :: res)

let sort_uniq cmp l =
  List.fast_sort cmp l |>
  List.fold_left (fun (eo, l) e' ->
      match eo with
      | None -> (Some e', l)
      | Some e when cmp e e' = 0 -> (eo, l)
      | Some e -> (Some e', e :: l))
    (None, []) |>
  (function
    | (None, _) -> []
    | (Some e, l) -> List.rev (e :: l))

let setify l =
  sort_uniq compare l

let normalize (point: ('a cursor) list) =
  setify point

let next_binary tmp s1 s2 =
  let pm w (_, p) = pattern_match p w in
  let o1 = binops `L s1 |>
           List.filter (pm s2.seen) |>
           List.map fst in
  let o2 = binops `R s2 |>
           List.filter (pm s1.seen) |>
           List.map fst in
  List.map (fun (o, l) ->
    o,
    { id = 0
    ; seen = Bnr (o, s1.seen, s2.seen)
    ; point = normalize (l @ tmp)
    }) (group_by_fst (o1 @ o2))

type p = string

module StateSet : sig
  type t
  val create: unit -> t
  val add: t -> p state ->
           [> `Added | `Found ] * p state
  val iter: t -> (p state -> unit) -> unit
  val elems: t -> (p state) list
end = struct
  open Hashtbl.Make(struct
    type t = p state
    let equal s1 s2 = s1.point = s2.point
    let hash s = Hashtbl.hash s.point
  end)
  type nonrec t =
    { h: int t
    ; mutable next_id: int }
  let create () =
    { h = create 500; next_id = 0 }
  let add set s =
    assert (s.point = normalize s.point);
    try
      let id = find set.h s in
      `Found, {s with id}
    with Not_found -> begin
      let id = set.next_id in
      set.next_id <- id + 1;
      Printf.printf "adding: %d [%s]\n"
        id (show_pattern s.seen);
      add set.h s id;
      `Added, {s with id}
    end
  let iter set f =
    let f s id = f {s with id} in
    iter f set.h
  let elems set =
    let res = ref [] in
    iter set (fun s -> res := s :: !res);
    !res
end

type table_key =
  | K of op * p state * p state

module StateMap = Map.Make(struct
  type t = table_key
  let compare ka kb =
    match ka, kb with
    | K (o, sl, sr), K (o', sl', sr') ->
        compare (o, sl.id, sr.id)
                (o', sl'.id, sr'.id)
end)

type rule =
  { name: string
  ; pattern: pattern
  }

let generate_table rl =
  let states = StateSet.create () in
  (* initialize states *)
  let ground =
    List.concat_map
      (fun r -> peel r.pattern r.name) rl |>
    group_by_fst
  in
  let find x d l =
    try List.assoc x l with Not_found -> d in
  let tmp = find (Atm Tmp) [] ground in
  let con = find (Atm AnyCon) [] ground in
  let () =
    List.iter (fun (seen, l) ->
      let point =
        if pattern_match (Atm Tmp) seen
        then normalize (tmp @ l)
        else normalize (con @ l)
      in
      let s = {id = 0; seen; point} in
      let flag, _ = StateSet.add states s in
      assert (flag = `Added)
    ) ground
  in
  (* setup loop state *)
  let map = ref StateMap.empty in
  let map_add k s' =
    map := StateMap.add k s' !map
  in
  let flag = ref `Added in
  let flagmerge = function
    | `Added -> flag := `Added
    | _ -> ()
  in
  (* iterate until fixpoint *)
  while !flag = `Added do
    flag := `Stop;
    let statel = StateSet.elems states in
    iter_pairs statel (fun (sl, sr) ->
      next_binary tmp sl sr |>
      List.iter (fun (o, s') ->
        let flag', s' =
          StateSet.add states s' in
        flagmerge flag';
        map_add (K (o, sl, sr)) s';
    ));
  done;
  let states =
    StateSet.elems states |>
    List.sort (fun s s' -> compare s.id s'.id) |>
    Array.of_list
  in
  (states, !map)

let intersperse x l =
  let rec go left right out =
    let out =
      (List.rev left @ [x] @ right) ::
      out in
    match right with
    | x :: right' ->
        go (x :: left) right' out
    | [] -> out
  in go [] l []

let rec permute = function
  | [] -> [[]]
  | x :: l ->
      List.concat (List.map
        (intersperse x) (permute l))

(* build all binary trees with ordered
 * leaves l *)
let rec bins build l =
  let rec go l r out =
    match r with
    | [] -> out
    | x :: r' ->
        go (l @ [x]) r'
          (fold_pairs
            (bins build l)
            (bins build r)
            out (fun (l, r) out ->
                   build l r :: out))
  in
  match l with
  | [] -> []
  | [x] -> [x]
  | x :: l -> go [x] l []

let products l ini f =
  let rec go acc la = function
    | [] -> f (List.rev la) acc
    | xs :: l ->
        List.fold_left (fun acc x ->
            go acc (x :: la) l)
          acc xs
  in go ini [] l

(* combinatorial nuke... *)
let rec ac_equiv =
  let rec alevel o = function
    | Bnr (o', l, r) when o' = o ->
        alevel o l @ alevel o r
    | x -> [x]
  in function
  | Bnr (o, _, _) as p
    when associative o ->
      products
        (List.map ac_equiv (alevel o p)) []
        (fun choice out ->
          List.concat_map
            (bins (fun l r -> Bnr (o, l, r)))
            (if commutative o
              then permute choice
              else [choice]) @ out)
  | Bnr (o, l, r)
    when commutative o ->
      fold_pairs
        (ac_equiv l) (ac_equiv r) []
        (fun (l, r) out ->
          Bnr (o, l, r) ::
          Bnr (o, r, l) :: out)
  | Bnr (o, l, r) ->
      fold_pairs
        (ac_equiv l) (ac_equiv r) []
        (fun (l, r) out ->
          Bnr (o, l, r) :: out)
  | x -> [x]

type action =
  | Switch of (int * action) list
  | Push of action
  | Pop of action
  | Set of string * action
  | Done

(* left-to-right matching of a set of patterns;
 * may raise if there is no lr matcher for the
 * pattern set *)
let lr_matcher
    (rmap: (op * (int * int) list) list array)
    (states: p state array)
    (rules: rule list)
    (name: string) =
  let rec aux ids pats k =
    Switch (List.map (fun id -> id,
        let id_ops = rmap.(id) in
        let atm_pats, bin_pats =
          List.filter (function
            | (Bnr (o, _, _), _) ->
                List.exists (fun (o', _) -> o' = o) id_ops
            | _ -> true) pats |>
          List.partition (fun (pat, _) -> is_atomic pat)
        in
        if bin_pats = [] then
          let matched_pats = List.filter (fun (pat, _) ->
              pattern_match pat states.(id).seen) atm_pats
          in
          let vars =
            List.filter_map (function
                | (Var (v, _), _) -> Some v
                | _ -> None) matched_pats |>
            setify
          in
          match vars with
          | [] -> k matched_pats
          | [v] -> Set (v, k matched_pats)
          | _ -> failwith "ambiguous var match"
        else
          let lhs_pats =
            List.map (function
                | (Bnr (o, pl, pr), c) ->
                    (pl, Bnrl (o, c, pr))
                | _ -> assert false) bin_pats
          in
          let lhs_ids, rhs_ids =
            List.split (List.concat_map snd id_ops) in
          let lhs_ids = setify lhs_ids
          and rhs_ids = setify rhs_ids in
          Push (aux lhs_ids lhs_pats (fun matched_pats ->
              (* using the patterns that have been matched
               * we can reduce the list of rhs states *)
              let rhs_ids = List.filter (fun id ->
                  let matched_lhs = function
                    | Bnrr (o, pl, _) ->
                        List.for_all (function
                          | (pm, Bnrl (_o', _, _)) ->
                              (* Eeh, not sure about all this. *)
                              (* o = o' && *) pattern_match pl pm
                          | _ -> assert false) matched_pats
                    | _ -> false
                  in
                  List.exists matched_lhs states.(id).point)
                  rhs_ids
              in
              let rhs_pats = List.map (function
                  | (pl, Bnrl (o, c, pr)) ->
                      (pr, Bnrr (o, pl, c))
                  | _ -> assert false) matched_pats
              in
              Pop (aux rhs_ids rhs_pats (fun matched_pats ->
                  let matched_pats = List.map (function
                      | (pr, Bnrr (o, pl, c)) ->
                          (Bnr (o, pl, pr), c)
                      | _ -> assert false) matched_pats
                  in
                  k matched_pats)))))
      ids)
  in
  let top_ids =
    Array.to_seq states |>
    Seq.filter_map (fun {id; point = p; _} ->
        if List.exists ((=) (Top name)) p then
          Some id
        else None) |>
    List.of_seq
  in
  let top_pats =
    List.filter_map (fun r ->
        if r.name = name then
          Some (r.pattern, Top ())
        else None) rules
  in
  aux top_ids top_pats (fun _ -> Done)

let invert_statemap n sm =
  let rmap = Array.create n [] in
  StateMap.iter (fun k s ->
      match k with
      | K (o, {id = idl; _}, {id = idr; _}) ->
          rmap.(s.id) <- (o, (idl, idr)) :: rmap.(s.id)
    ) sm;
  Array.map group_by_fst rmap
