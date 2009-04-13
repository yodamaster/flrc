(* The Intel P to C/Pillar Compiler *)
(* Copyright (C) Intel Corporation, October 2006 *)

(* For when things go wrong *)

signature FAIL = sig
    val assert : string * string * string * (unit -> bool) -> unit
                 (* struct, routine, failure msg, assert fn *)
    val fail : string * string * string -> 'a  (* struct, routine, msg *)
    val unimplemented : string * string * string -> 'a
                        (* struct, routine, what *)
end;

structure Fail :> FAIL = struct

    fun fail (s, r, m) = Assert.fail (s ^ "." ^ r ^ ": " ^ m)
    fun assert (s, r, m, assert) =
        if assert () then
            ()
        else
            fail (s, r, m)
    fun unimplemented (s, r, w) = fail (s, r, w ^ " unimplemented")

end;