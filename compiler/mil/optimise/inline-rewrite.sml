(* The Intel P to C/Pillar Compiler *)
(* Copyright (C) Intel Corporation, May 2008 *)
(* Description: Inline/Clone rewriter implementation. *)

(* Signature of a Mil Inline Rewriter. *)
signature MIL_INLINE_REWRITER = 
  sig
    val program : PassData.t * IMil.t -> unit
  end

(* Operations that can be performed by the inliner. *)
datatype inlineOperation =
         (* Inline a copy of the target func into the call site. *)
         InlineFunctionCopy
         (* Inline the target func code into the call site. *)
       | InlineFunction
         (* Clone the target func and update the call site. *)
       | CloneFunction
       | NoOp

(* TODO EB:  Create an interface to help the policies to choose inlineable
 * calls.
fun inlineableCall (milCall: Mil.call) : bool = 
    case milCall
     of M.CCode v => true
      | M.CDirectClosure (v, c) => true
      | M.CClosure _ => false
      | M.CExtern _ => false
      | _ => fail ("inlineableCall", 
                   "Cannot inline calls to CClosure.")
      | M.CExtern _ => fail ("inlineCallSite", 
                             "Cannot inline calls to extern.")
*)                                               

(* Mil Inline rewriter functor. *)
functor MilInlineRewriterF (
  (* The type of the information to be passed to the policy and 
   * optimize functions. *)
  type policyInfo
  (* Function  to analyze the  IMil program and initialize  the inline
   * information. *)
  val analyze : PassData.t * IMil.t -> policyInfo
  (* The call instruction identifier. *)
  type callId
  (* Helper function to map a callId to an IMil call instruction. *)
  val callIdToCall : policyInfo * IMil.t * callId -> IMil.instr
  (* Helper function to inform the policyInfo the creation of new
   * blocks during an inline expansion.
   * Example:
   *
   *  f ()                   f ()
   *   B1                     B1
   *    c1: g ()              B3'
   *             after         c2': h ()
   *             ========>    
   *  g ()       inlining    g ()
   *   B3                     B3
   *    c2: h ()               c2: h ()
   *
   * During the inlining of g () at c1, B3 was copied into B3'.
   * The inliner calls the
   *   associateCallToCallId (info, imil, c1, B3, B3') 
   * to inform the policyInfo holder. *)
  val associateCallToCallId : policyInfo * (* The inline information. *)
                              IMil.t     * (* The imil program. *)
                              callId     * (* Call site being inlined. *)
                              IMil.block * (* Block being copied. *)
                              IMil.block   (* The copy. *) -> unit
  (* The inline rewrite operation to be performed: inline or clone.*)
  val rewriteOperation : callId -> inlineOperation
  (* The policy function takes an IMil.t program and returns a list of
   * call  sites to  be inlined.  The policy  function will  be called
   * multiple times until it returns an empty list of call sites. *)
  val policy : policyInfo * PassData.t * IMil.t -> callId list
  (* The optimizer is an optional function called after the call sites 
   * are inlined. If it is specified as NONE, it is not called. *)
  val optimizer : (policyInfo * PassData.t * IMil.t * 
                   IMil.instr list -> unit) option

) :> MIL_INLINE_REWRITER  = 
struct 

  type policyInfo            = policyInfo
  val  analyze               = analyze
  type callId                = callId
  val  callIdToCall          = callIdToCall
  val  associateCallToCallId = associateCallToCallId
  val  rewriteOperation      = rewriteOperation
  val  policy                = policy
  val  optimizer             = optimizer
                       
  (* Short aliases. *)
  structure MOU = MilOptUtils
  structure PD  = PassData
  structure M   = Mil

  (* Reports a fail message and exit the program.
   * param f : The function name.
   * param s : the messagse. *)
  fun fail (f, m) = Fail.fail ("inline-rewrite.sml ", f, m)

  (* If an optimizer was provided, call it after inlining. *)
  fun optimizeIMil (info : policyInfo, d : PassData.t, 
                    imil : IMil.t, ils : IMil.instr list) : unit = 
      case optimizer
       of NONE => ()
        | SOME optimize => optimize (info, d, imil, ils)
                           
  (* Inline the call site "c".  Find F (that contains c), G (called by
   * c) and inline G at c. *)
  fun inlineCallSite (info : policyInfo, 
                      d    : PD.t, 
                      c    : callId, 
                      imil : IMil.t,
                      dup  : bool) : IMil.instr list =
      let
        val callInstr : IMil.instr = callIdToCall (info, imil, c)
        val milCall = case MOU.iinstrToTransfer (imil, callInstr)
                       of SOME (M.TCall x) => #1 x
                        | SOME (M.TTailCall x) => #1 x
                        | _ => fail ("inlineCallSite", 
                                     "Invalid IMil call instruction.")
        val fname = case milCall
                     of M.CCode v => v
                      | M.CDirectClosure (v, c) => v
                      | M.CClosure _ => 
                        fail ("inlineCallSite", 
                              "Cannot inline calls to CClosure.")
                      | M.CExtern _ => 
                        fail ("inlineCallSite", 
                              "Cannot inline calls to extern.")

        fun mapBlk (old : IMil.block, new : IMil.block) : unit = 
            associateCallToCallId (info, imil, c, old, new)
      in
        if dup then
          IMil.Cfg.inlineMap (imil, fname, callInstr, SOME mapBlk, NONE)
        else
          IMil.Cfg.inline (imil, fname, callInstr)
      end

  (* Inline the call site "c".  Find F (than contains c), G (called by
   * c) and inline G at c. *)
  fun cloneCallSite (info : policyInfo, 
                     d    : PD.t, 
                     c    : callId, 
                     imil : IMil.t) : IMil.instr list =
      fail ("cloneCallSite", "Function not implemented yet.")
      
  (*  Rewrite the call  site "c".  Check the  operation and  inline or
   * clone call site as appropriate. *)
  fun rewriteCallSite (info : policyInfo, 
                       d    : PD.t, 
                       c    : callId, 
                       imil : IMil.t) : IMil.instr list =
      case rewriteOperation (c)
       of InlineFunction => inlineCallSite (info, d, c, imil, false)
        | InlineFunctionCopy => inlineCallSite (info, d, c, imil, true)
        | CloneFunction => cloneCallSite (info, d, c, imil)
        | NoOp => nil
                  
  (* Call the rewriteCallSite for each call site in the list. *)
  fun rewriteCallSites (info          : policyInfo,
                        d             : PD.t, 
                        callsToInline : callId list, 
                        imil          : IMil.t) : IMil.instr list =
      let
        val ils = List.map (callsToInline, 
                         fn c => rewriteCallSite (info, d, c, imil))
      in 
        List.concat (ils)
      end

  (* Iterative inlining keeps selecting call sites and inlining until
   * the policy function returns an empty list of call sites to inline. *)
  fun iterativeRewrite (info : policyInfo, 
                        d    : PD.t, 
                        imil : IMil.t) : unit =
      Try.exec
        (fn () =>
            let
              (* Collect the call sites to inline. *)
              val callsToRewrite : callId list = policy (info, d, imil)
              val () = Try.require (not (List.isEmpty (callsToRewrite)))
              (* Inline the call sites. *)
              val il = rewriteCallSites (info, d, callsToRewrite, imil)
              (* Optimize before next inline iteration. *)
              val () = optimizeIMil (info, d, imil, il)
            in 
              (* Keep inlining/cloning until policy returns a nil list. *)
              iterativeRewrite (info, d, imil)
            end)
      
  fun program (d : PD.t, imil : IMil.t) : unit =
      let
        val info = analyze (d, imil)
      in
        iterativeRewrite (info, d, imil)
      end
      
end (* Functor MilInlineRewriterF *)