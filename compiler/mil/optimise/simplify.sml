(* The Intel P to C/Pillar Compiler *)
(* Copyright (C) Intel Corporation, July 2007 *)

signature MIL_SIMPLIFY =
sig
  val simplify : PassData.t * IMil.t * IMil.WorkSet.ws -> unit
  val program : PassData.t * IMil.t -> unit
  val pass : (BothMil.t, BothMil.t) Pass.t
end;

signature REDUCE = 
sig
  type t
  val reduce : (PassData.t * IMil.t * IMil.WorkSet.ws) * t -> IMil.item List.t option
end

structure MilSimplify :> MIL_SIMPLIFY = 
struct

  val passname = "MilSimplify"

  structure M = Mil
  structure P = Prims
  structure MU = MilUtils
  structure POM = PObjectModel
  structure I = IMil
  structure IInstr = I.IInstr
  structure IGlobal = I.IGlobal
  structure IFunc = I.IFunc
  structure IBlock = I.IBlock
  structure Var = I.Var
  structure Use = I.Use
  structure Def = I.Def
  structure Item = I.Item
  structure Enumerate = I.Enumerate
  structure WS = I.WorkSet
  structure MCG = MilCallGraph
  structure IPLG = ImpPolyLabeledGraph
  structure IVD = Identifier.ImpVariableDict
  structure PD = PassData
  structure SD = StringDict
  structure VS = M.VS

  structure Chat = ChatF (struct 
                            type env = PD.t
                            val extract = PD.getConfig
                            val name = passname
                            val indent = 0
                          end)

  val <- = Try.<-
  val <@ = Try.<@
  val <! = Try.<!
  val << = Try.<<
  val oo = Try.oo
  val om = Try.om
  val or = Try.or
  val || = Try.||
  val @@ = Utils.Function.@@
  infix 3 << @@ oo om <!
  infix 4 or || 

 (* Reports a fail message and exit the program.
  * param f: The function name.
  * param s: the messagse. *)
  val fail = 
   fn (f, m) => Fail.fail ("simplify.sml", f, m)

 (* Fail and reports a message if assert is false.
  * param f: The function name.
  * param s: the messagse. *) 
  val assert = 
   fn (f, m, assert) => if assert then () else fail (f, m)

  val (debugPassD, debugPass) =
      Config.Debug.mk (passname ^ ":debug", "Debug the simplifier according to debug level")

  val mkDebug : string * string * int -> (Config.Debug.debug * (PassData.t -> bool)) = 
   fn (tag, description, level) =>
      let
        val (debugD, debug) = 
            Config.Debug.mk (passname ^ ":" ^ tag, description)
        val debug = 
         fn d => 
            let
              val config = PD.getConfig d
            in debug config orelse 
               (debugPass config andalso Config.debugLevel (config, passname) >= level)
            end
      in (debugD, debug)
      end

  val (checkPhaseD, checkPhase) =
      mkDebug ("check-phase", "Check IR between each phase", 0)

  val (showPhaseD, showPhase) =
      mkDebug ("show-phase", "Show IR between each phase", 1)

  val (showReductionsD, showReductions) = 
      mkDebug ("show", "Show each successful reduction attempt", 1)

  val (showEachD, showEach) = 
      mkDebug ("show-each", "Show each reduction attempt", 2)

  val (checkIrD, checkIr) =
      mkDebug ("check-ir", "Check IR after each successful reduction", 2)

  val (showIrD, showIr) =
      mkDebug ("show-ir", "Show IR after each successful reduction", 2)

  val debugs = [debugPassD, showEachD, showReductionsD, showIrD, checkIrD, showPhaseD, checkPhaseD]

  val mkLogFeature : string * string * int -> (Config.Feature.feature * (PassData.t -> bool)) = 
   fn (tag, description, level) =>
      let
        val (featureD, feature) = 
            Config.Feature.mk (passname ^ ":" ^ tag, description)
        val feature = 
         fn d => 
            let
              val config = PD.getConfig d
            in feature config orelse 
               (Config.logLevel (config, passname) >= level)
            end
      in (featureD, feature)
      end

  val (statPhaseF, statPhase) = 
      mkLogFeature ("stat-phase", "Show stats between each phase", 2)

  val mkFeature : string * string -> (Config.Feature.feature * (PassData.t -> bool)) = 
   fn (tag, description) =>
      let
        val (featureD, feature) = 
            Config.Feature.mk (passname ^ ":" ^ tag, description)
        val feature = 
         fn d => feature (PD.getConfig d)
      in (featureD, feature)
      end

  val (noIterateF, noIterate) = 
      mkFeature ("no-iterate", "Don't iterate simplification and cfg simplification")

  val (skipUnreachableF, skipUnreachable) = 
      mkFeature ("skip-unreachable", "Skip unreachable object elimination")

  val (skipSimplifyF, skipSimplify) = 
      mkFeature ("skip-simplify", "Skip simplification")

  val (skipCfgF, skipCfg) = 
      mkFeature ("skip-cfg-simplify", "Skip cfg simplification")

  val (skipEscapeF, skipEscape) = 
      mkFeature ("skip-escape", "Skip escape analysis")

  val (skipRecursiveF, skipRecursive) = 
      mkFeature ("skip-recursive", "Skip recursive analysis")

  val features = [statPhaseF, noIterateF, skipUnreachableF, skipSimplifyF, skipCfgF, skipEscapeF, skipRecursiveF]

  structure Click = 
  struct
    val localNms =
        [("BlockKill",       "Blocks killed"                  ),
         ("BlockMerge",      "Blocks merged"                  ),
         ("CallDirect",      "Calls made direct"              ),
         ("CaseCollapse",    "Cases collapsed"                ),
         ("CaseReduce",      "Cases reduced"                  ),
         ("CopyProp",        "Copies/Constants propagated"    ),
         ("CutReduce",       "Cuts reduced"                   ),
         ("DoubleArith",     "Double arith ops reduced"       ),
         ("DoubleCmp",       "Double cmp ops reduced"         ),
         ("EvalDirect",      "Evals made direct"              ),
         ("FloatArith",      "Float arith ops reduced"        ),
         ("FloatCmp",        "Float cmp ops reduced"          ),
         ("FunctionGetFv",   "Function fv projections reduced"),
         ("IdxGet",          "Index Get operations reduced"   ),
         ("InlineOnce",      "Functions inlined once"         ),
         ("TInlineOnce",     "Thunks inlined once"            ),
         ("LoopFlatten",     "Loop tuple args flattened"      ),
         ("NumConv",         "Numeric conversions reduced"    ),
         ("PhiReduce",       "Phi transfers reduced"          ),
         ("Prim",            "Primitives reduced"             ),


         ("SwitchToSetCond", "Switches converted to SetCond"  ),
         ("SwitchETAReduce", "Case switches converted to Goto"),
         ("ThunkGetFv",      "Thunk fv projections reduced"   ),
         ("ThunkVal",        "ThunkValues reduced"            ),
         ("ThunkToThunkVal", "Thunks made ThunkValues"        ),
         ("TupleSub",        "Tuple subscripts reduced"       )

        ]

    val localNms = 
        [
         ("BetaSwitch",       "Cases beta reduced"             ),
         ("CallInline",       "Calls inlined"                  ),
         ("CollapseSwitch",   "Cases collapsed"                ),
         ("DCE",              "Dead instrs/globals eliminated" ),
         ("EtaSwitch",        "Cases eta reduced"              ),
         ("Globalized",       "Objects globalized"             ),
         ("IdxGet",           "Index gets reduced"             ),
         ("KillParameters",   "Block parameter lists trimmed"  ),
         ("LoopFlatten",      "Loop arguments flattened"       ),
         ("MakeDirect",       "Call/Evals made direct"         ),
         ("MergeBlocks",      "Blocks merged"                  ),
         ("ObjectGetKind",    "ObjectGetKinds reduced"         ),
         ("PFunctionGetFv",   "Closure fv projections reduced" ),
         ("PFunctionInitCode","Closure code ptrs killed"       ),
         ("PrimPrim",         "Primitives reduced"             ),
         ("PrimToLen",        "P Nom/Dub -> length reductions" ),
         ("PSetGet",          "SetGet ops reduced"             ),
         ("PSetNewEta",       "SetNew ops eta reduced"         ),
         ("PSumProj",         "Sum projections reduced"        ),
         ("PSetQuery",        "SetQuery ops reduced"           ),
         ("PSetCond",         "SetCond ops reduced"            ),
         ("PruneCuts",        "Cut sets pruned"                ),
         ("PruneFx",          "Fx sets pruned"                 ),
         ("Simple",           "Simple moves eliminated"        ),
         ("SwitchToSetCond",  "Cases converted to SetCond"     ),
         ("TCut",             "Cuts eliminated"                ),
         ("TGoto",            "Gotos eliminated"               ),
         ("ThunkGetFv",       "Thunk fv projections reduced"   ),
         ("ThunkGetValue",    "ThunkGetValue ops reduced"      ),
         ("ThunkInitCode",    "Thunk code ptrs killed"         ), 
         ("ThunkSpawnFX",     "Spawn fx pruned"                ),
         ("ThunkValueBeta",    "ThunkValues beta reduced"      ),
         ("ThunkValueEta",    "ThunkValues eta reduced"        ),
         ("TupleSub",         "Tuple subscripts reduced"       ),
         ("Unreachable",      "Unreachable objects killed"     )
        ]
    val globalNm = 
     fn s => passname ^ ":" ^ s

    val nmMap = 
        let
          val check = 
           fn ((nm, info), d) => 
              if SD.contains (d, nm) then
                fail ("LocalStats", "Duplicate stat")
              else
                SD.insert (d, nm, globalNm nm)
          val _ = List.fold (localNms, SD.empty, check)
        in ()
        end

    val clicker = 
     fn s => 
        let
          val nm = globalNm s
          val click = 
           fn pd => 
              let
                val () = if showEach pd orelse showReductions pd then
                           (print "Reduction#";print s;print "\n")
                         else ()
              in PD.click (pd, nm)
              end
        in click
        end

    val stats = List.map (localNms, fn (nm, info) => (globalNm nm, info))

    val betaSwitch = clicker "BetaSwitch"
    val callInline = clicker "CallInline"
    val collapseSwitch = clicker "CollapseSwitch"
    val dce = clicker "DCE"
    val etaSwitch = clicker "EtaSwitch"
    val killParameters = clicker "KillParameters"
    val unreachable = clicker "Unreachable"
    val globalized = clicker "Globalized"
    val idxGet = clicker "IdxGet"
    val loopFlatten = clicker "LoopFlatten"
    val makeDirect = clicker "MakeDirect"
    val mergeBlocks = clicker "MergeBlocks"
    val pSumProj = clicker  "PSumProj"
    val pSetQuery = clicker  "PSetQuery"
    val pSetCond = clicker  "PSetCond"
    val pSetGet = clicker  "PSetGet"
    val pSetNewEta = clicker "PSetNewEta"
    val thunkSpawnFx = clicker "ThunkSpawnFX"
    val objectGetKind = clicker "ObjectGetKind"
    val pFunctionInitCode = clicker "PFunctionInitCode"
    val pFunctionGetFv = clicker "PFunctionGetFv"
    val primPrim = clicker "PrimPrim"
    val primToLen = clicker "PrimToLen"
    val pruneCuts = clicker "PruneCuts"
    val pruneFx = clicker "PruneFx"
    val simple = clicker "Simple"
    val switchToSetCond = clicker "SwitchToSetCond"
    val tCut = clicker "TCut"
    val tGoto = clicker "TGoto"
    val thunkGetFv = clicker "ThunkGetFv"
    val thunkGetValue = clicker "ThunkGetValue"
    val thunkInitCode = clicker "ThunkInitCode"
    val thunkValueBeta = clicker "ThunkValueBeta"
    val thunkValueEta = clicker "ThunkValueEta"
    val tupleSub = clicker "TupleSub"

    val wrap : (PD.t -> unit) * ((PD.t * I.t * WS.ws) * 'a -> 'b option) 
               -> ((PD.t * I.t * WS.ws) * 'a -> 'b option) =
     fn (click, reduce) => 
     fn args => 
        let
          val r = reduce args
          val () = if isSome r then click (#1 (#1 args)) else ()
        in r
        end
                           
  end   (*  structure Click *)


  val try = 
   fn (clicker, reduce) => Click.wrap (clicker, Try.lift reduce)


   val getUniqueInit =
       Try.lift
       (fn (imil, v) =>
           let
             val {inits, others} = Use.splitUses (imil, v)
             val init = <@ Use.toInstruction o Try.V.singleton @@ inits
           in init
           end)

  
  structure FuncR : REDUCE = 
  struct
    type t = I.iFunc

    val reduce = 
     fn _ => NONE

  end (* structure FuncR *)

  structure GlobalR : REDUCE =
  struct
    type t = I.iGlobal 

    val simple = 
        let
          val f = 
           fn ((d, imil, ws), (g, v, s)) => 
              let
                val () = Use.replaceUses (imil, v, s)
                val () = IGlobal.delete (imil, g)
              in []
              end
        in try (Click.simple, f)
        end

    val reduce = 
        Try.lift 
          (fn (s as (d, imil, ws), g) => 
              let
                val t = 
                    (case <@ IGlobal.toGlobal g
                      of (v, M.GSimple oper) => <@ simple (s, (g, v, oper))
                       | _ => Try.fail ())
              in t
              end)


  end (* structure GlobalR *)

  structure TransferR : REDUCE =
  struct
    type t = I.iInstr * M.transfer

    val tGoto =
        let
          val f = 
           fn ((d, imil, ws), (i, M.T {block, arguments})) =>
              let
                val () = Try.V.isEmpty arguments
                val b = IInstr.getIBlock (imil, i)
                val oEdges = IBlock.outEdges (imil, b)
                val succ = 
                    (case oEdges
                      of [(_, succ)] => succ
                       | _ => Try.fail ())
                val () = 
                    (case IBlock.preds (imil, succ)
                      of [_] => ()
                       | _ => Try.fail ())
                val () = IBlock.merge (imil, b, succ)
              in []
              end
        in try (Click.tGoto, f)
        end

    structure TCase = 
    struct
      val betaSwitch = 
       fn {get, eq, dec, con} => 
          let
            val f = 
             fn ((d, imil, ws), (i, {on, cases, default})) =>
                let
                  val c = <@ get (imil, on)
                  val eqToC = fn (c', _) => eq (c, c')
                  val {yes, no} = Vector.partition (cases, eqToC)
                  val tg = 
                      (case (Vector.length yes, default)
                        of (0, SOME tg) => tg
                         | (1, _) => #2 (Vector.sub (yes, 0))
                         | _ => Try.fail ())
                  val mi = M.TGoto tg
                  val () = IInstr.replaceTransfer (imil, i, mi)
                in [I.ItemInstr i]
                end
          in try (Click.betaSwitch, f)
          end

     (* XXX This has a bug in it - can loop -leaf *)
      val collapseSwitch = 
       fn {get, eq, dec, con} => 
          let
            val f = 
             fn ((d, imil, ws), (i, {on, cases, default})) =>
                let
                  val {block, arguments} = MU.Target.Dec.t (<- default)
                  val () = Try.V.isEmpty arguments
                  val iFunc = IInstr.getIFunc (imil, i)
                  val fallthruBlock = IFunc.getBlockByLabel (imil, iFunc, block)
                  val params = IBlock.getParameters (imil, fallthruBlock)
                  val () = Try.V.isEmpty params
                  val () = Try.require (IBlock.isEmpty (imil, fallthruBlock))
                  val t = IBlock.getTransfer' (imil, fallthruBlock)
                  val {on = on2, cases = cases2, default = default2} = <@ dec t
                  val () = Try.require (MU.Operand.eq (on, on2))
                  val check = fn x => (fn (y, _) => not (eq (x, y)))
                  val notAnArmInFirst = 
                   fn (x, _) => Vector.forall (cases, check x)
                  val cases2 = Vector.keepAll (cases2, notAnArmInFirst)
                  val cases = Vector.concat [cases, cases2]
                  val t = con {on = on, cases = cases, default = default2}
                  val () = IInstr.replaceTransfer (imil, i, t)
                in [I.ItemInstr i]
                end
          in try (Click.collapseSwitch, f)
          end

      val switch = fn ops => (betaSwitch ops) or (collapseSwitch ops)
                             
      val tCase1 = 
          let
            val get = (fn (imil, s) => MU.Simple.Dec.sConstant s)
            val eq = MU.Constant.eq
            val dec = MU.Transfer.Dec.tCase
            val con = M.TCase
            val f = switch {get = get, eq = eq, dec = dec, con = con}
          in f
          end

            (* Switch ETA Reduction:
             *
             * Example: Switch with operand "a", constant options c1, c2, ..., 
             * =======  cn, and default.
             *
             * Before the reduction          After the reduction
             * --------------------          -------------------
             *
             * Case (a)                   |  Goto L (c, a, d)
             * of c1 => goto L (c, c1, d) |      
             *    c2 => goto L (c, c2, d) |
             *    ...                     |
             *    cn => goto L (c, cn, d) |
             *     _ => goto L (c,  a, d) |
             *     
             *)
      val etaSwitch = 
          let
            val f = 
             fn ((d, imil, ws), (i, {on, cases, default})) =>
                let
                  (* Turn the constants into operands *)
            val cases = Vector.map (cases, fn (a, tg) => (M.SConstant a, tg))
                                   (* Add the default, using the scrutinee as the comparator *)
            val cases = 
                case default
                 of SOME tg => Utils.Vector.cons ((on, tg), cases)
                  | NONE => cases
                              (* Ensure all labels are the same, and get an arbitrary one *)
            val labels = Vector.map (cases, #block o MU.Target.Dec.t o #2)
            val () = Try.require (Utils.Vector.allEq (labels, op =))
            val label = Try.V.sub (labels, 0)
                                  (* Map each row (c, c2, d) to (SOME c, NONE, SOME d), where NONE indicates
                                   * that the element is equal either to the scrutinee, or to the particular 
                                   * constant guarding this branch. (Essentially, we mask out these elements,
                                   * and insist that the rest do not vary between rows) *)
            val canonize = 
             fn (a, M.T {block, arguments}) => 
                let
                  val mask = 
                   fn b => if MU.Operand.eq (a, b) orelse MU.Operand.eq (on, b) then
                             NONE
                           else 
                             SOME b
                  val arguments = Vector.map (arguments, mask)
                in arguments
                end
            val argumentsV = Vector.map (cases, canonize)
                                        (* Transpose the argument vectors into column vectors, and ensure that
                                         * each column contains all of the same elements (either all NONE), or
                                         * all SOME c for the same c *)
            val argumentsVT = Utils.Vector.transpose argumentsV
            val columnOk = 
             fn v => Utils.Vector.allEq (v, fn (a, b) => Option.equals (a, b, MU.Operand.eq))
            val () = Try.require (Vector.forall (argumentsVT, columnOk))
            val arguments = Try.V.sub (argumentsV, 0)
            val arguments = Vector.map (arguments, fn a => Utils.Option.get (a, on))
            val t = M.TGoto (M.T {block = label, arguments = arguments})
            val () = IInstr.replaceTransfer (imil, i, t)
                in [I.ItemInstr i]
                end
          in try (Click.etaSwitch, f)
          end

            (* Turn a switch into a setCond:
             * case b of true => goto L1 ({}) 
             *        | false => goto L1 {a}
             *   ==  x = setCond(b, a);
             *       goto L1(x);
             *)
      val switchToSetCond = 
          let
            val f = 
             fn ((d, imil, ws), (i, r)) =>
                let
                  val config = PD.getConfig d
                  val {on, trueBranch, falseBranch} = <@ MU.Transfer.isBoolIf (M.TCase r)
                  val M.T {block = l1, arguments = args1} = trueBranch
                  val M.T {block = l2, arguments = args2} = falseBranch
                  val () = Try.require (l1 = l2)
                  val arg1 = Try.V.singleton args1
                  val arg2 = Try.V.singleton args2
                  val () = <@ MU.Constant.Dec.cOptionSetEmpty <! MU.Simple.Dec.sConstant @@ arg2
                  val contents = <@ MU.Def.Out.pSet <! Def.toMilDef o Def.get @@ (imil, <@ MU.Simple.Dec.sVariable arg1)
                  val t = MilType.Typer.operand (config, IMil.T.getSi imil, contents)
                  val v = IMil.Var.new (imil, "sset", t, false)
                  val ni = M.I {dest = SOME v, 
                                rhs  = M.RhsPSetCond {bool = on, ofVal = contents}}
                  val mv = IInstr.insertBefore (imil, ni, i)
                  val tg = 
                      M.T {block = l1, 
                           arguments = Vector.new1 (M.SVariable v)}
                  val goto = M.TGoto tg
                  val () = IInstr.replaceTransfer (imil, i, goto)
                in [I.ItemInstr i, I.ItemInstr mv]
                end
          in try (Click.switchToSetCond, f)
          end

      val reduce = tCase1 or switchToSetCond or etaSwitch
    end (* structure TCase *)

    val tCase = TCase.reduce

    structure TInterProc = 
    struct

      val callInlineCode = 
          Try.lift 
            (fn ((d, imil, ws), (i, fname)) => 
                let
                  val uses = Use.getUses (imil, fname)
                  val use = Try.V.singleton uses
                  val iFunc = IFunc.getIFuncByName (imil, fname)
                  val () = Try.require (not (IFunc.getRecursive (imil, iFunc)))
                  val is = IFunc.inline (imil, fname, i)
                in is
                end)

      val callInlineClosure = 
          Try.lift 
          (fn ((d, imil, ws), (i, {cls, code})) => 
              let
                val iFunc = IFunc.getIFuncByName (imil, code)
                (* We allow inlining of "recursive" functions,
                 * as long as all uses are known, there is only
                 * one call, and that call is not a recursive call. *)
                val () = Try.require (not (IInstr.isRec (imil, i)))
                val () = Try.require (not (IFunc.getEscapes (imil, iFunc)))
                (* Ensure that this code pointer only escapes
                 * into this closure.  *)
                val uses = Use.getUses (imil, code)
                val getCode = (<@ #code <! MU.Rhs.Dec.rhsPFunctionInit <! Use.toRhs)
                           || (<- o <@ MU.Global.Dec.gPFunction o #2 <! Use.toGlobal)
                val isInit = 
                 fn u => 
                    (case getCode u
                      of SOME code2 => code2 = code
                       | NONE => false)
                val {yes = inits, no = nonInits} = Vector.partition (uses, isInit)
                val () = Try.V.lenEq (nonInits, 1)
                val () = Try.V.lenEq (inits, 1)
                val is = IFunc.inline (imil, code, i)
                val fix = 
                 fn init => 
                    Try.exec
                      (fn () => 
                          (case init
                            of I.UseGlobal g => 
                               let
                                 val (v, mg) = <@ IGlobal.toGlobal g
                                 val code = MU.Global.Dec.gPFunction mg
                                 val mg = M.GPFunction NONE
                                 val () = IGlobal.replaceMil (imil, g, I.GGlobal (v, mg))
                               in ()
                               end
                             | I.UseInstr i => 
                               let
                                 val mi = <@ IInstr.toInstruction i
                                 val M.I {dest, rhs} = mi
                                 val {cls, code, fvs} = <@ MU.Rhs.Dec.rhsPFunctionInit rhs
                                 val rhs = M.RhsPFunctionInit {cls = cls, code = NONE, fvs = fvs}
                                 val mi = M.I {dest = dest, rhs = rhs}
                                 val () = IInstr.replaceInstruction (imil, i, mi)
                               in ()
                               end
                             | I.Used => ()))
                val () = Vector.foreach (uses, fix)
              in is
              end)

      val callInline = 
          let
            val f = 
             fn (s, (i, {callee, ret, fx})) =>
                let
                  val {call, args} = <@ MU.InterProc.Dec.ipCall callee
                  val is = 
                      (case call
                        of M.CCode fname => <@ callInlineCode (s, (i, fname))
                         | M.CDirectClosure r => <@ callInlineClosure (s, (i, r))
                         | _ => Try.fail ())
                  val is = List.map (is, I.ItemInstr)
                in is
                end
          in try (Click.callInline, f)
          end

      val thunkValueBeta = 
          let
            val f = 
             fn ((d, imil, ws), (i, {callee, ret, fx})) =>
                let
                  val t = MU.Eval.thunk o #eval <! MU.InterProc.Dec.ipEval @@ callee
                  val get = (#ofVal <! MU.Def.Out.thunkValue <! Def.toMilDef o Def.get) 
                         || (#ofVal <! MU.Rhs.Dec.rhsThunkValue o MU.Instruction.rhs <! getUniqueInit)
                            
                  val s = <@ get (imil, t)
                  val () = 
                      let
                        val succs = IInstr.succs (imil, i)
                        fun activate b =
                            WS.addInstr (ws, 
                                         IBlock.getLabel (imil, b))
                            
                        val () = List.foreach (succs, activate)
                      in ()
                      end
                  val t = 
                      (case ret
                        of M.RNormal {block, rets, ...} =>
                           let
                             val () = assert ("thunkValueBeta", "Bad number of ret vars", Vector.length rets = 1)
                             val v = Vector.sub (rets, 0)
                             val () = Use.replaceUses (imil, v, s)
                             val tg = M.T {block = block,
                                           arguments = Vector.new0 ()}
                           in M.TGoto tg
                           end
                         | M.RTail => M.TReturn (Vector.new1 s))
                  val () = IInstr.replaceTransfer (imil, i, t)
                in [I.ItemInstr i]
                end
          in try (Click.thunkValueBeta, f)
          end

      val makeDirectCall = 
          Try.lift 
            (fn ((d, imil, ws), call) => 
                let
                  val {cls, code = {exhaustive, possible}} = <@ MU.Call.Dec.cClosure call
                  val code = 
                      (case (exhaustive, VS.toList possible)
                        of (true, [code]) => code
                         | _ => 
                           let
                             val get = (<@ #code <! MU.Def.Out.pFunction <! Def.toMilDef o Def.get)
                                    || (<@ #code <! MU.Rhs.Dec.rhsPFunctionInit o MU.Instruction.rhs <! getUniqueInit)
                             val code = <@ get (imil, cls)
                           in code
                           end)
                  val call = M.CDirectClosure {cls = cls, code = code}
                in call
                end)

      val makeDirectEval = 
          Try.lift 
            (fn ((d, imil, ws), eval) => 
                let
                  val {thunk, code = {exhaustive, possible}} = <@ MU.Eval.Dec.eThunk eval
                  val code = 
                      (case (exhaustive, VS.toList possible)
                        of (true, [code]) => code
                         | _ => 
                           let
                             val get = (<@ MU.Rhs.Dec.rhsThunkInit <! Def.toRhs o Def.get)
                                    || (<@ MU.Rhs.Dec.rhsThunkInit o MU.Instruction.rhs <! getUniqueInit)
                             val f = <@ #code <! get @@ (imil, thunk)
                           in f
                           end)
                  val eval = M.EDirectThunk {thunk = thunk, code = code}
                in eval
                end)

      val makeDirect = 
          let
            val f = 
             fn ((s as (d, imil, ws)), (i, {callee, ret, fx})) =>
                 let
                   val callee = 
                       (case callee
                         of M.IpCall {call, args} => M.IpCall {call = <@ makeDirectCall (s, call), args = args}
                          | M.IpEval {typ, eval} => M.IpEval {eval = <@ makeDirectEval (s, eval), typ = typ})
                   val t = M.TInterProc {callee = callee, ret = ret, fx = fx}
                   val () = IInstr.replaceTransfer (imil, i, t)
                 in [I.ItemInstr i]
                 end
          in try (Click.makeDirect, f)
          end

      val pruneCuts = 
          let
            val f = 
             fn ((d, imil, ws), (i, {callee, ret, fx})) =>
                 let
                   val {rets, block, cuts} = <@ MU.Return.Dec.rNormal ret
                   val fails = Effect.contains (fx, Effect.Fails)
                   val () = Try.require (not fails)
                   val () = Try.require (MU.Cuts.hasCuts cuts)
                   val ret = M.RNormal {rets = rets, block = block, cuts = MU.Cuts.none}
                   val t = M.TInterProc {callee = callee, ret = ret, fx = fx}
                   val () = IInstr.replaceTransfer (imil, i, t)
                 in [I.ItemInstr i]
                 end
          in try (Click.pruneCuts, f)
          end

      val pruneFx = 
          let
            val f = 
             fn ((d, imil, ws), (i, {callee, ret, fx})) =>
                 let
                   val {possible, exhaustive} = MU.InterProc.codes callee
                   val () = Try.require exhaustive
                   val folder = 
                    fn (codeptr, codeFx) =>
                       let
                         val iFunc = IFunc.getIFuncByName (imil, codeptr)
                         val fx = IFunc.getEffects (imil, iFunc)
                       in Effect.union (codeFx, fx)
                       end
                   val codeFx = VS.fold (possible, Effect.Total, folder)
                   val () = Try.require (not (Effect.subset (fx, codeFx)))
                   val fx = Effect.intersection (fx, codeFx)
                   val t = M.TInterProc {callee = callee, ret = ret, fx = fx}
                   val () = IInstr.replaceTransfer (imil, i, t)
                 in [I.ItemInstr i]
                 end
          in try (Click.pruneFx, f)
          end

      val reduce = callInline
                     or thunkValueBeta
                     or makeDirect 
                     or pruneCuts
                     or pruneFx

    end (* structure TInterProc *)

    val tInterProc = TInterProc.reduce 

    val tReturn = fn _ => NONE

    val tCut = 
        let
          val f = 
           fn ((d, imil, ws), (i, {cont, args, cuts})) =>
              let
                val l = <@ MU.Rhs.Dec.rhsCont <! Def.toRhs o Def.get @@ (imil, cont)
                val tgt = M.T {block = l, arguments = args}
                val t = M.TGoto tgt
                val () = IInstr.replaceTransfer (imil, i, t)
              in [I.ItemInstr i]
              end
        in try (Click.tCut, f)
        end

    val tPSumCase = 
        let
          val get = 
              Try.lift 
                (fn (imil, oper) => 
                    let
                      val v = <@ MU.Simple.Dec.sVariable oper
                      val nm = #tag <! MU.Def.Out.pSum <! Def.toMilDef o Def.get @@ (imil, v)
                    in nm 
                    end)
          val eq = fn (nm, nm') => nm = nm'
          val dec = MU.Transfer.Dec.tPSumCase
          val con = M.TPSumCase
          val f = TCase.switch {get = get, eq = eq, dec = dec, con = con}
        in f
        end

    val reduce = 
     fn (state, (i, t)) =>
        let
          val r = 
              (case t
                of M.TGoto tg => tGoto (state, (i, tg))
                 | M.TCase sw => tCase (state, (i, sw))
                 | M.TInterProc ip => tInterProc (state, (i, ip))
                 | M.TReturn rts => tReturn (state, (i, rts))
                 | M.TCut ct => tCut (state, (i, ct))
                 | M.TPSumCase sw => tPSumCase (state, (i, sw)))
       in r
       end

  end (* structure TransferR *)

  structure LabelR : REDUCE =
  struct
    type t = I.iInstr * (M.label * M.variable Vector.t)

    structure LabelOpts = 
    struct
      val mergeBlocks =
          let
            val f = 
             fn ((d, imil, ws), (i, (l, parms), pred)) => 
                let
                  val () = 
                      (case IBlock.succs (imil, pred)
                        of [_] => ()
                         | _ => Try.fail ())
                  val tf = IBlock.getTransfer' (imil, pred)
                  (* Since there are no parameters, even switches with multiple out edges
                   * can be merged.
                   *)
                  val _ = <@ MU.Transfer.isIntraProcedural tf
                  val b = IInstr.getIBlock (imil, i)
                  val () = IBlock.merge (imil, pred, b)
                in []
                end
          in try (Click.mergeBlocks, f)
          end

      val killParameters =
          let
            val f = 
             fn ((d, imil, ws), (i, (l, parms), (preds, pcount))) => 
                let
                  (* This is mostly straightforward: just look for parameters
                   * that are either unused, or are constant.  Most of the 
                   * ugliness arises because of the possibility that a single 
                   * predecessor block targets this block via multiple paths 
                   * in a switch, e.g.
                   * B1:
                   *   switch (a) 
                   *        1 => goto B2 (3)
                   *        2 => goto B2 (4)
                   *)
                  val () = Try.require (not (List.isEmpty preds))
                  val ts =  List.map (preds, fn p => IBlock.getTransfer (imil, p))
                  val tfs = List.map (ts, <@ IInstr.toTransfer)
                  (* list of vector of targets *)
                  val tgs = List.map (tfs, <@ MU.Transfer.isIntraProcedural)
                  (* vector of targets *)
                  val tgs = Vector.concat tgs
                  (* Keep only those targeting this block *)
                  (* inargs is a vector of vectors*)
                  val inargs = Vector.keepAllMap (tgs, fn (M.T {block, arguments}) => 
                                                          if block = l then SOME arguments else NONE)
                  (* Get the columns.  This is essentially the RHS of a phi instruction *)
                  val inargsT = Utils.Vector.transpose inargs                              
                  val () = assert ("killParameters", "Bad phi", Vector.length inargsT = pcount)
                  val phis = Vector.zip (parms, inargsT)

                  (* Trace back the SSA edges before rewriting to capture potentially
                   * newly dead instructions *)
                  val usedBy = Utils.Vector.concatToList (List.map (ts, fn t => IInstr.getUsedBy (imil, t)))

                  (* Mark true those to be removed *)
                  val kill = Array.array (pcount, false)
                  val progress = ref false

                  val killIthParm = 
                   fn i =>
                      let
                        val () = progress := true
                        val () = Array.update (kill, i, true)
                      in ()
                      end

                  val replaceIthParm = 
                   fn (i, p, inarg) =>
                      let
                        val () = progress := true
                        val () = Array.update (kill, i, true)
                        val () = Use.replaceUses (imil, p, inarg)
                      in ()
                      end

                  val allEq = fn v => Utils.Vector.allEq (v, MU.Operand.eq)

                  val doPhi = 
                   fn (i, (pv, args)) =>
                      if Vector.isEmpty (Use.getUses (imil, pv)) then
                        killIthParm i 
                      else
                        let
                          val loopCarried = fn i => MU.Operand.eq (i, M.SVariable pv)
                          (* Filter out the loop carried*)
                          val args = Vector.keepAll (args, not o loopCarried)
                          (* Ensure that all non loop carried are equal *)
                          (* xi = phi (c, c, xi, c, xi, x) *)
                          val () = 
                              if (allEq args andalso Vector.length args > 0) then
                                replaceIthParm (i, pv, Vector.sub (args, 0))
                              else
                                ()
                        in ()
                        end
                  val () = Vector.foreachi (phis, doPhi)

                  (* If no progress has been made, bail out *)
                  val () = Try.require (!progress)

                  val killVector = 
                   fn v => Vector.keepAllMapi (v, 
                                            fn (i, elt) => if Array.sub (kill, i) then NONE else SOME elt)
                  val rewriteTarget = 
                   fn (t as (M.T {block, arguments})) =>
                      if block = l then
                        M.T {block = block,
                             arguments = killVector arguments}
                      else t                         

                  val rewriteTransfer = 
                   fn tf => MU.Transfer.mapOverTargets (tf, rewriteTarget)

                  val rewriteTransfer = 
                      fn t =>
                         (case IInstr.toTransfer t
                           of SOME tf => IInstr.replaceTransfer (imil, t, rewriteTransfer tf)
                            | NONE => fail ("rewriteTransfer", "Not a transfer"))

                  val () = List.foreach (ts, rewriteTransfer)
                  val parms = killVector parms
                  val () = IInstr.replaceLabel (imil, i, (l, parms))
                  val ls = List.map (i::ts, I.ItemInstr) @ usedBy
                in ls
                end
          in try (Click.killParameters, f)
          end

      val labelOpts = 
          Try.lift
          (fn (s as (d, imil, ws), (i, (l, parms))) => 
              (case (IInstr.preds (imil, i), Vector.length parms)
                of ([pred], 0) => <@ mergeBlocks (s, (i, (l, parms), pred))
                 | (_, 0) => Try.fail ()
                 | r => <@ killParameters (s, (i, (l, parms), r))))
    end (* structure LabelOpts *)


    structure Flatten = 
    struct

      datatype 'a object = OTuple of 'a Vector.t
                         | OThunk of 'a

      type arg = M.operand object option
      type argVec = arg Vector.t

      datatype transfer = 
               TGoto of {i : IMil.iInstr, outArgs : argVec}
             | TSwitch of {i : IMil.iInstr, cases : argVec option Vector.t, default : argVec option}

      val transferFold = 
       fn (t, a, f) => 
          (case t
            of TGoto {i, outArgs} => f (outArgs, a)
             | TSwitch {i, cases, default} => 
               let
                 val option =
                  fn (vo, a) => Option.fold (vo, a, f)
                 val a = Vector.fold (cases, a, option)
                 val a = option (default, a)
               in a
               end)
          
      val transferMap = 
       fn (t, f) => 
          (case t
            of TGoto {i, outArgs} => TGoto {i = i, outArgs = f outArgs}
             | TSwitch {i, cases, default} => 
               let
                 val option = fn opt => Option.map (opt, f)
                 val res = 
                     TSwitch {i = i, cases = Vector.map (cases, option), default = option default}
               in res
               end)


      val oper2Object = 
          Try.lift
          (fn (d, imil, a) =>
              let
                val v = <@ MU.Simple.Dec.sVariable a
                val res = 
                    (case <@ Def.toMilDef o Def.get @@ (imil, v)
                      of MU.Def.DefGlobal (M.GTuple {inits, ...})      => OTuple inits
                       | MU.Def.DefGlobal (M.GThunkValue {ofVal, ...}) => OThunk ofVal
                       | MU.Def.DefRhs (M.RhsTuple {inits, vtDesc})    => 
                         let
                           val () = Try.require (MU.VtableDescriptor.immutable vtDesc andalso 
                                                 not (MU.VtableDescriptor.hasArray vtDesc))
                         in OTuple inits
                         end
                       | MU.Def.DefRhs (M.RhsThunkValue {typ, thunk = NONE, ofVal}) => OThunk ofVal
                       | _                              => Try.fail ())
              in res
              end)

      val outArgs2Objects = 
       fn (d, imil, aa) => Vector.map (aa, fn a => oper2Object (d, imil, a))
                           

      val analyzeSwitch = 
       fn (d, imil, i, {on, cases, default}, l) => 
          let     
            val help = 
             fn (M.T {block, arguments}) => 
                if block = l then
                  SOME (outArgs2Objects (d, imil, arguments))
                else
                  NONE
                  
            val cases = Vector.map (cases, fn (a, tg) => help tg)
            val default = Utils.Option.bind (default, help)
            val res = TSwitch {i = i, cases = cases, default = default}
          in res
          end
         
      val analyzeTransfer = 
       fn (d, imil, i, l) =>
          (case IInstr.toTransfer i
            of SOME t => 
               (case t
                 of M.TGoto (M.T {block, arguments}) => 
                    SOME (TGoto {i = i, outArgs = outArgs2Objects (d, imil, arguments)})
                  | M.TCase sw     => SOME (analyzeSwitch (d, imil, i, sw, l))
                  | M.TPSumCase sw => SOME (analyzeSwitch (d, imil, i, sw, l))
                  | _ => NONE)
             | NONE => fail ("analyzeTransfer", "Not a transfer"))
          
      val analyzePred = 
       fn (d, imil, b, l) => 
          analyzeTransfer (d, imil, IBlock.getTransfer (imil, b), l)
          
      val analyzeInEdges = 
          Try.lift
            (fn (d, imil, i, l) => 
                let
                  val block = IInstr.getIBlock (imil, i)
                                          
                  (* Each def is a triple containing:
                   *  the transfer instruction
                   *  the index of the switch arm if appropriate 
                   *  the shapes of the def, if any
                   *)
                  val defs = 
                      let
                        val preds = IBlock.preds (imil, block)
                        val help = fn b => <@ analyzePred (d, imil, b, l)
                        val defs = List.map (preds, help)
                      in defs
                      end

                  val config = PD.getConfig d
                  val si = IMil.T.getSi imil
                  val typeOfObject = 
                   fn object => 
                      (case object
                        of OTuple ts => OTuple (MilType.Typer.operands (config, si, ts))
                         | OThunk t  => OThunk (MilType.Typer.operand (config, si, t)))

                  val summarizeArgs = 
                   fn objects => Vector.map (objects, fn opt => Option.map (opt, typeOfObject))

                  val combineObject =
                      Try.lift 
                        (fn (objO, tobjO) => 
                            (case (<- objO, <- tobjO)
                              of (OTuple v, OTuple ts) => 
                                 let
                                   val () = Try.require (Vector.length v = Vector.length ts)
                                 in OTuple ts
                                 end
                               | (OThunk v, OThunk t) => OThunk t
                               | _ => Try.fail ()))
                      
                  val combineObjects = 
                   fn (objects, tobjects) => 
                      Vector.map2 (objects, tobjects, combineObject)
                      
                  val ok = 
                   fn (transfer, summary) => 
                      (case summary
                        of NONE => 
                           let
                             val help = 
                              fn (objects, opt) => 
                                 (case opt
                                   of NONE => SOME (summarizeArgs objects)
                                    | SOME summary => SOME (combineObjects (objects, summary)))
                                 
                             val opt = 
                                 transferFold (transfer, NONE, help)
                           in opt
                           end
                         | SOME tobjects => 
                           SOME (transferFold (transfer, tobjects, combineObjects)))
                      
                  val summary = Try.<- (List.fold (defs, NONE, ok))
                in (summary, defs)
                end)
          
      val analyzeUses =
       fn (d, imil, parms) => 
          let
            val analyzeVar = 
             fn v => 
                let
                  val uses = Use.getUses (imil, v)
                  val ok = 
                   fn use => 
                      case (Use.toRhs use, Use.toTransfer use)
                       of (SOME (M.RhsTupleSub _), _) => true
                        | (SOME (M.RhsThunkGetValue _), _) => true
                        | (_, SOME (M.TInterProc {callee = M.IpEval _, ...})) => true
                        | _ => false
                  val isOk = Vector.forall (uses, ok)
                in isOk
                end
            val parmsOk = Vector.map (parms, analyzeVar)
          in parmsOk
          end

      val rewriteBlock = 
       fn (d, imil, worklist, i, (l, parms), defTypes) => 
          let
            val config = PD.getConfig d

            val rewriteParm = 
             fn (v, obj) => 
                (case obj
                  of SOME (OTuple ts) => 
                     let
                       val vnew = Var.clone (imil, v)
                       val mkvar = fn (i, t) => Var.related (imil, v, Int.toString i, t, false)
                       val vs = Vector.mapi (ts, mkvar)
                       val aa = Vector.map (vs, M.SVariable)
                       val fks = Vector.map (ts, fn t => MU.FieldKind.fromTyp (config, t))
                       val vtd = MU.Tuple.vtdImmutable fks
                       val rhs = MU.Tuple.new (vtd, aa)
                       val mi = M.I {dest = SOME vnew, rhs = rhs}
                       val () = Use.replaceUses (imil, v, M.SVariable vnew)
                       val inew = IInstr.insertAfter (imil, i, mi)
                       val () = WS.addInstr (worklist, inew)
                       val uses = Use.getUses (imil, vnew)
                       val () = WS.addUses (worklist, uses)
                     in vs
                     end
                   | SOME (OThunk t) => 
                     let
                       val vnew = Var.clone (imil, v)
                       val vval = Var.related (imil, v, "contents", t, false)
                       val a = M.SVariable vval
                       val fk = MU.FieldKind.fromTyp (config, t)
                       val mi = M.I {dest = SOME vnew, 
                                     rhs = M.RhsThunkValue {typ = fk, thunk = NONE, ofVal = a}}
                       val () = Use.replaceUses (imil, v, M.SVariable vnew)
                       val inew = IInstr.insertAfter (imil, i, mi)
                       val () = WS.addInstr (worklist, inew)
                       val uses = Use.getUses (imil, vnew)
                       val () = WS.addUses (worklist, uses)
                     in Vector.new1 vval
                     end
                   | ONone => Vector.new1 v)
            val parmsV = 
                Vector.map2 (parms, defTypes, rewriteParm)
            val parms = Vector.concatV parmsV
            val () = IInstr.replaceLabel (imil, i, (l, parms))
            val () = WS.addInstr (worklist, i)
          in ()
         end

      val rewriteInEdges = 
       fn (d, imil, worklist, defs) => 
          let 
            val rewriteOutArg = 
             fn (arg, object) => 
                (case object
                  of NONE => Vector.new1 arg
                   | SOME (OThunk arg) => Vector.new1 arg
                   | SOME (OTuple args) => args)

            val rewriteTarget = 
             fn (M.T {block, arguments}, objects) => 
                let
                  val argumentsV = 
                      Vector.map2 (arguments, objects, rewriteOutArg)
                  val arguments = Vector.concatV argumentsV
                  val tg = 
                      M.T {block = block, 
                           arguments = arguments}
                in tg
                end

            val rewriteGoto = 
             fn {i, outArgs} => 
                let
                  val used = IInstr.getUsedBy (imil, i)
                  val () = WS.addItems (worklist, used)
                  val mt = 
                      (case IInstr.toTransfer i
                        of SOME (M.TGoto tg) => 
                           M.TGoto (rewriteTarget (tg, outArgs))
                         | _ => fail ("rewriteGoto", "Bad transfer"))
                  val () = IInstr.replaceTransfer (imil, i, mt)
                  val () = WS.addInstr (worklist, i)
                in ()
                end
               
            val rewriteCase = 
             fn {i = i, cases = arms, default = dflt} => 
                let
                  val rewriteArm = 
                   fn ((a, tg), opt) => 
                      (case opt
                        of SOME objects => 
                           (a, rewriteTarget (tg, objects))
                         | NONE => (a, tg))
                  val rewriteSwitch = 
                   fn {on = a, cases = arms', default = dflt'} => 
                      {on = a, 
                       cases = Vector.map2 (arms', arms, rewriteArm),
                       default = case (dflt', dflt)
                                  of (_, NONE) => NONE
                                   | (SOME tg, SOME objects) => 
                                     SOME (rewriteTarget (tg, objects))
                                   | _ => fail ("rewriteCase", "Bad switch default")}
                  val used = IInstr.getUsedBy (imil, i)
                  val () = WS.addItems (worklist, used)
                  val mt = 
                      (case IInstr.toTransfer i
                        of SOME (M.TCase sw) => 
                           M.TCase (rewriteSwitch sw)
                         | SOME (M.TPSumCase sw) => 
                           M.TPSumCase (rewriteSwitch sw)
                         | _ => fail ("rewriteSwitch", "Bad transfer"))
                  val () = IInstr.replaceTransfer (imil, i, mt)
                  val () = WS.addInstr (worklist, i)
                in ()
                end

            val rewriteInEdge = 
             fn t => 
                (case t
                  of TGoto a =>  rewriteGoto a
                   | TSwitch a => rewriteCase a)

            val () = List.foreach (defs, rewriteInEdge)
                     
          in ()
          end

      val loopFlatten = 
          let
            val f = 
             fn ((d, imil, worklist), (i, (l, parms))) =>
                let
                  val (summary, defs) = <@ analyzeInEdges (d, imil, i, l)
                  val parmsOk = analyzeUses (d, imil, parms)
                  val () = Try.require (Vector.length summary = 
                                        Vector.length parmsOk)
                  val ok = 
                   fn (obj, parmOk) => 
                      (case (obj, parmOk)
                        of (SOME _, true) => true
                         | _ => false)
                  val oks = 
                      Vector.map2 (summary, parmsOk, ok)
                  val () = Try.require (Vector.exists (oks, fn a => a))
                 (* At this point, we have at least one parameter for which 
                  * 1. All uses are subscripts
                  * 2. All defs on all in-edges are tuple introductions of the
                  *    correct shape.
                  *)
                  val filter1 = 
                   fn (obj, ok) => 
                      if ok then 
                        obj 
                      else
                        NONE
                  val summary = Vector.map2 (summary, oks, filter1)
                  val filter2 = 
                   fn t => 
                      transferMap (t, fn objects => Vector.map2 (objects, oks, filter1))
                  val defs = List.map (defs, filter2)
                  val () = rewriteBlock (d, imil, worklist, i, (l, parms), summary)
                  val () = rewriteInEdges (d, imil, worklist, defs)
                in []
                end
          in try (Click.loopFlatten, f)
          end
    end (* structure Flatten *)

    val reduce = LabelOpts.labelOpts or Flatten.loopFlatten

  end (* structure LabelR *)

  structure InstructionR : REDUCE =
  struct
    type t = I.iInstr * M.instruction

    val globalize = 
        let
          val f = 
           fn ((d, imil, ws), (i, M.I {dest, rhs})) => 
              let
                val add = 
                 fn (v, g) =>
                    let
                      val gv = Var.related (imil, v, "", Var.typ (imil, v), true)
                      val () = IInstr.delete (imil, i)
                      val g = IGlobal.build (imil, gv, g)
                      val () = WS.addGlobal (ws, g)
                      val () = Use.replaceUses (imil, v, M.SVariable gv)
                    in ()
                    end
                    
                val const = 
                 fn c => 
                    (case c
                      of M.SConstant c => true
                       | M.SVariable v => Var.isGlobal (imil, v))
                   
                val consts = 
                 fn ops => Vector.forall (ops, const)
                           
                val () = 
                    (case rhs
                      of M.RhsTuple {vtDesc, inits} =>
                         if MU.VtableDescriptor.immutable vtDesc andalso
                            (not (MU.VtableDescriptor.hasArray vtDesc)) andalso
                            Vector.forall (inits, const) 
                         then
                           add (<- dest, M.GTuple {vtDesc = vtDesc, inits = inits})
                         else
                           Try.fail ()
                       | M.RhsThunkValue {typ, thunk, ofVal} =>
                         if const ofVal then
                           add (<@ Utils.Option.atMostOneOf (thunk, dest), 
                                M.GThunkValue {typ = typ, ofVal = ofVal})
                         else
                           Try.fail ()
                       | M.RhsPFunctionInit {cls, code, fvs} =>
                         if Option.forall (code, fn v => Var.isGlobal (imil, v)) andalso 
                            Vector.isEmpty fvs 
                         then
                           add (<@ Utils.Option.atMostOneOf (cls, dest), M.GPFunction code)
                         else
                           Try.fail ()
                       | M.RhsPSetNew op1 => 
                         if const op1 then
                           add (<- dest, M.GPSet op1)
                         else
                           Try.fail ()
                       | M.RhsPSum {tag, typ, ofVal} => 
                         if const ofVal then
                           add (<- dest, M.GPSum {tag = tag, typ = typ, ofVal = ofVal})
                         else
                           Try.fail ()
                       | _ => Try.fail ())
              in []
              end
        in try (Click.globalized, f)
        end

   val getClosureOrThunkParameters = 
    Try.lift
      (fn (imil, c) =>
          let
            val (v, vs) = 
                case IMil.Def.get (imil, c)
                 of IMil.DefParameter iFunc =>
                    (case IFunc.getCallConv (imil, iFunc)
                      of M.CcClosure {cls, fvs} => (cls, fvs)
                       | M.CcThunk {thunk, fvs} => (thunk, fvs)
                       | _ => Try.fail ())
                  | _ => Try.fail ()
            val () = Try.require (v = c)
            val opers = Vector.map (vs, M.SVariable)
          in opers
          end)


    val simple = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, s)) =>
              let
                val v = <- dest
                val () = Use.replaceUses (imil, v, s)
                val () = IInstr.delete (imil, i)
              in []
              end
        in try (Click.simple, f)
        end

    val primToLen = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, {prim, createThunks, args})) =>
              let
                val dv = <- dest
                val p = <@ MU.Prims.Dec.prim prim
                val () = Try.require (p = Prims.PNub)
                val v1 = <@ MU.Simple.Dec.sVariable o Try.V.singleton @@ args
                val {prim, args, ...} = <@ MU.Rhs.Dec.rhsPrim <! Def.toRhs o Def.get @@ (imil, v1)
                val p = <@ MU.Prims.Dec.prim prim
                val () = Try.require (p = Prims.PDom)
                val arrv = <@ MU.Simple.Dec.sVariable o Try.V.singleton @@ args
                val config = PD.getConfig d
                val uintv = IMil.Var.related (imil, dv, "uint", MU.UIntp.t config, false)
                val ni = 
                    let
                      val rhs = POM.OrdinalArray.length (config, arrv)
                      val mi = M.I {dest = SOME uintv, rhs = rhs}
                      val ni = IInstr.insertBefore (imil, mi, i)
                    in ni
                    end
                val () = 
                    let
                      val rhs = MU.Rational.fromUIntp (config, M.SVariable uintv)
                      val mi = M.I {dest = SOME dv, rhs = rhs}
                      val () = IInstr.replaceInstruction (imil, i, mi)
                    in ()
                    end
              in [I.ItemInstr ni, I.ItemInstr i]
              end
        in try (Click.primToLen, f)
        end

    val primPrim = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, {prim, createThunks, args})) =>
              let
                val dv = <- dest

                val p = <@ MU.Prims.Dec.prim prim

                val milToPrim = 
                 fn p => 
                    (case p
                      of M.SConstant c => MU.Prims.Operation.fromMilConstant c
                       | M.SVariable v => 
                         (case Def.toMilDef o Def.get @@ (imil, v)
                           of SOME def => MU.Prims.Operation.fromDef def
                            | NONE => Prims.OOther))

                val config = PD.getConfig d

                val rr = P.reduce (config, p, Vector.toList args, milToPrim)

                val l = 
                    (case rr
                      of P.RrUnchanged => Try.fail ()
                       | P.RrBase new  =>
                         let
                           val () = Use.replaceUses (imil, dv, new)
                           val () = IInstr.delete (imil, i)
                         in []
                         end
                       | P.RrConstant c =>
                         let
                           val gv = Var.new (imil, "mrt", MU.Rational.t, true)
                           val mg = MU.Prims.Constant.toMilGlobal (PD.getConfig d, c)
                           val g = IGlobal.build (imil, gv, mg)
                           val () = Use.replaceUses (imil, dv, M.SVariable gv)
                           val () = IInstr.delete (imil, i)
                         in [I.ItemGlobal g]
                         end
                       | P.RrPrim (p, ops) =>
                         let
                           val rhs = M.RhsPrim {prim = P.Prim p, 
                                                createThunks = createThunks,
                                                args = Vector.fromList ops}
                           val ni = M.I {dest = SOME dv, rhs = rhs}
                           val () = IInstr.replaceInstruction (imil, i, ni)
                         in [I.ItemInstr i]
                         end)
              in l
              end
        in try (Click.primPrim, f)
        end

    val prim = primPrim or primToLen

    val tuple = fn (state, (i, dest, r)) => NONE

    val tupleSub = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, tf)) =>
              let
                val dv = <- dest
                val fi = MU.TupleField.field tf
                val tup = MU.TupleField.tup tf
                val tupDesc = MU.TupleField.tupDesc tf
                val idx = 
                    (case fi
                      of M.FiFixed i => i
                       | M.FiVariable p => 
                         let
                           val fields = MU.TupleDescriptor.numFixed tupDesc
                           val idx = <@ IntArb.toInt <! MU.Constant.Dec.cIntegral <! MU.Simple.Dec.sConstant @@ p
                         in fields + idx
                         end
                       | _ => Try.fail ())
                val inits = #inits <! MU.Def.Out.tuple <! Def.toMilDef o Def.get @@ (imil, tup)
                val p = Try.V.sub (inits, idx)
                val () = Use.replaceUses (imil, dv, p)
                val () = IInstr.delete (imil, i)
              in []
              end
        in try (Click.tupleSub, f)
        end

    val tupleSet = fn (state, (i, dest, r)) => NONE

    val tupleInited = fn (state, (i, dest, r)) => NONE

    val idxGet = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, {idx, ofVal})) =>
              let
                val dv = <- dest
                val nm = <@ MU.Constant.Dec.cName <! MU.Simple.Dec.sConstant @@ ofVal
                val idx = <@ MU.Global.Dec.gIdx o #2 <! Def.toGlobal o Def.get @@ (imil, idx)
                val offset = <@ M.ND.lookup (idx, nm)
                val p = M.SConstant (MU.UIntp.int (PD.getConfig d, offset))
                val () = Use.replaceUses (imil, dv, p)
                val () = IInstr.delete (imil, i)
              in []
              end
        in try (Click.idxGet, f)
        end

    val cont = fn (state, (i, dest, r)) => NONE

    val objectGetKind = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, v)) =>
              let
                val dv = <- dest
                val pokO = 
                    Try.try
                      (fn () => 
                          case <@ Def.toMilDef o Def.get @@ (imil, v)
                           of MU.Def.DefRhs rhs  => <@ MU.Rhs.pObjKind rhs
                            | MU.Def.DefGlobal g => <@ MU.Global.pObjKind g)
                val pok = 
                    case pokO
                     of SOME pok => pok
                      | NONE => <@ MU.PObjKind.fromTyp (Var.typ (imil, v))
                val p = M.SConstant (M.CPok pok)
                val () = Use.replaceUses (imil, dv, p)
                val () = IInstr.delete (imil, i)
              in []
              end
        in try (Click.objectGetKind, f)
        end
        
    val thunkMk = fn (state, (i, dest, r)) => NONE

    val thunkInit = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, {typ, thunk, fx, code, fvs})) =>
              let
                 val fcode = <- code
                 val iFunc = IFunc.getIFuncByName (imil, fcode)
                 val () = Try.require (not (IFunc.getEscapes (imil, iFunc)))
                 val uses = IMil.Use.getUses (imil, fcode)
                 val () = Try.V.lenEq (uses, 1)
                 val rhs = M.RhsThunkInit {typ = typ, thunk = thunk, fx = fx, code = NONE, fvs = fvs}
                 val mi = M.I {dest = dest, rhs = rhs}
                 val () = IInstr.replaceInstruction (imil, i, mi)
              in [I.ItemInstr i]
              end
        in try (Click.thunkInitCode, f)
        end

    val thunkGetFv = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, {thunk, idx, ...})) =>
              let
                val v = <- dest
                val fv =
                    case getUniqueInit (imil, thunk)
                     of SOME init => 
                        let
                          val {fvs, ...} = <@ MU.Rhs.Dec.rhsThunkInit o MU.Instruction.rhs @@ init
                          val (_, fv) = Try.V.sub (fvs, idx)
                        in fv
                        end
                      | NONE => 
                        let
                          val fvs = <@ getClosureOrThunkParameters (imil, thunk)
                          val fv = Try.V.sub (fvs, idx)
                        in fv
                        end
                val () = Use.replaceUses (imil, v, fv)
                val () = IInstr.delete (imil, i)
              in []
              end
        in try (Click.thunkGetFv, f)
        end

    val thunkValue = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, {thunk, ofVal, ...})) =>
              let
                val dv = <@ Utils.Option.atMostOneOf (dest, thunk)
                val vv = <@ MU.Simple.Dec.sVariable ofVal
                val {callee, ret, ...} = <@ MU.Transfer.Dec.tInterProc <! Def.toTransfer o Def.get @@ (imil, vv)
                val vv' = Try.V.singleton o #rets <! MU.Return.Dec.rNormal @@ ret
                val () = assert ("thunkValue", "Strange def", vv = vv')
                val thunk' = MU.Eval.thunk o #eval <! MU.InterProc.Dec.ipEval @@ callee
                val () = Use.replaceUses (imil, dv, M.SVariable thunk')
                val () = IInstr.delete (imil, i)
              in []
              end
        in try (Click.thunkValueEta, f)
        end

    val thunkGetValue = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, {typ, thunk})) =>
              let
                val dv = <- dest
                val ofVal = 
                    (case <@ Def.toMilDef o Def.get @@ (imil, thunk)
                      of MU.Def.DefRhs (M.RhsThunkValue {ofVal, ...})  => ofVal
                       | MU.Def.DefGlobal (M.GThunkValue {ofVal, ...}) => ofVal
                       | MU.Def.DefRhs (M.RhsThunkMk _) =>
                         #ofVal <! MU.Rhs.Dec.rhsThunkValue o MU.Instruction.rhs <! getUniqueInit @@ (imil, thunk)
                       | _ => Try.fail ())
                val () = Use.replaceUses (imil, dv, ofVal)
                val () = IInstr.delete (imil, i)
              in []
              end
        in try (Click.thunkGetValue, f)
        end

    val thunkSpawn = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, {thunk, fx, typ})) =>
              let
                val code = <@ #code <! MU.Rhs.Dec.rhsThunkInit <! Def.toRhs o Def.get @@ (imil, thunk)
                val iFunc = IFunc.getIFuncByName (imil, code)
                val fx2 = IFunc.getEffects (imil, iFunc)
                val () = Try.require (not (Effect.subset (fx, fx2)))
                val fx = Effect.intersection (fx, fx2)
                val r = {thunk = thunk, fx = fx, typ = typ}
                val rhs = M.RhsThunkSpawn r
                val mi = M.I {dest = dest, rhs = rhs}
                val () = IInstr.replaceInstruction (imil, i, mi)
              in [I.ItemInstr i]
              end
        in try (Click.thunkSpawnFx, f)
        end

    val pFunctionMk = fn (state, (i, dest, r)) => NONE

    val pFunctionInit = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, {cls, code, fvs})) =>
              let
                 val fcode = <- code
                 val iFunc = IFunc.getIFuncByName (imil, fcode)
                 val () = Try.require (not (IFunc.getEscapes (imil, iFunc)))
                 val uses = IMil.Use.getUses (imil, fcode)
                 val () = Try.V.lenEq (uses, 1)
                 val rhs = M.RhsPFunctionInit {cls = cls, code = NONE, fvs = fvs}
                 val mi = M.I {dest = dest, rhs = rhs}
                 val () = IInstr.replaceInstruction (imil, i, mi)
              in [I.ItemInstr i]
              end
        in try (Click.pFunctionInitCode, f)
        end

    val pFunctionGetFv = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, {cls, idx, ...})) =>
              let
                val v = <- dest
                val fv =
                    case getUniqueInit (imil, cls)
                     of SOME init => 
                        let
                          val {fvs, ...} = <@ MU.Rhs.Dec.rhsPFunctionInit o MU.Instruction.rhs @@ init
                          val (_, fv) = Try.V.sub (fvs, idx)
                        in fv
                        end
                      | NONE => 
                        let
                          val fvs = <@ getClosureOrThunkParameters (imil, cls)
                          val fv = Try.V.sub (fvs, idx)
                        in fv
                        end
                val () = Use.replaceUses (imil, v, fv)
                val () = IInstr.delete (imil, i)
              in []
              end
        in try (Click.pFunctionGetFv, f)
        end

    val pSetNew = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, p)) =>
              let
                val dv = <- dest
                val v = <@ MU.Simple.Dec.sVariable p
                val setv =   
                    (case <@ Def.toMilDef o Def.get @@ (imil, v)
                      of MU.Def.DefRhs (M.RhsPSetGet setv) => setv
                       | _ => Try.fail ())
                val p = M.SVariable setv
                val () = Use.replaceUses (imil, dv, p)
                val () = IInstr.delete (imil, i)
              in []
              end
        in try (Click.pSetNewEta, f)
        end

    val pSetGet = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, v)) =>
              let
                val dv = <- dest
                val c = 
                    (case <@ Def.toMilDef o Def.get @@ (imil, v)
                      of MU.Def.DefRhs (M.RhsPSetNew c)             => c
                       | MU.Def.DefRhs (M.RhsPSetCond {ofVal, ...}) => ofVal
                       | MU.Def.DefGlobal (M.GPSet c)               => c
                       | _ => Try.fail ())
                val () = Use.replaceUses (imil, dv, c)
                val () = IInstr.delete (imil, i)
              in []
              end 
         in try (Click.pSetGet, f)
         end

    val pSetCond = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, {bool, ofVal})) =>
              let
                val c = <@ MU.Simple.Dec.sConstant ofVal
                val rhs = 
                    (case MU.Bool.toBool (PD.getConfig d, c)
                      of SOME true => M.RhsPSetNew ofVal
                       | SOME false => M.RhsSimple (M.SConstant (M.COptionSetEmpty))
                       | NONE => Try.fail (Chat.warn0 (d, "Unexpected boolean constant")))
                val mi = M.I {dest = dest,
                              rhs = rhs}
                val () = IInstr.replaceInstruction (imil, i, mi)
              in [I.ItemInstr i]
              end
        in try (Click.pSetCond, f)
        end

    val pSetQuery = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, r)) => 
              let
                val T = M.SConstant (MU.Bool.T (PD.getConfig d))
                val F = M.SConstant (MU.Bool.F (PD.getConfig d))

                val v = <- dest
                val b = 
                    case r
                     of M.SConstant (M.COptionSetEmpty) => F
                      | M.SVariable v => 
                        (case <@ Def.toMilDef o Def.get @@ (imil, v)
                          of MU.Def.DefRhs (M.RhsPSetNew _)            => T
                           | MU.Def.DefRhs (M.RhsPSetCond {bool, ...}) => bool
                           | MU.Def.DefGlobal (M.GPSet op2)            => T
                           | _ => Try.fail ())
                      | _ => Try.fail ()
                val () = Use.replaceUses (imil, v, b)
                val () = IInstr.delete (imil, i)
              in []
              end
        in try (Click.pSetQuery, f)
        end

    val pSum = fn (state, (i, dest, r)) => NONE

    val pSumProj = 
        let
          val f = 
           fn ((d, imil, ws), (i, dest, {typ, sum, tag})) => 
              let
                val v = <- dest
                val {ofVal, ...} = <@ MU.Def.Out.pSum <! Def.toMilDef o Def.get @@ (imil, v)
                val () = Use.replaceUses (imil, v, ofVal)
                val () = IInstr.delete (imil, i)
              in []
              end
        in try (Click.pSumProj, f)
        end

    val simplify = 
     fn (state, (i, M.I {dest, rhs})) =>
        let
          val r = 
              case rhs
               of M.RhsSimple r         => simple (state, (i, dest, r))
                | M.RhsPrim r           => prim (state, (i, dest, r))
                | M.RhsTuple r          => tuple (state, (i, dest, r))
                | M.RhsTupleSub r       => tupleSub (state, (i, dest, r))
                | M.RhsTupleSet r       => tupleSet (state, (i, dest, r))
                | M.RhsTupleInited r    => tupleInited (state, (i, dest, r))
                | M.RhsIdxGet r         => idxGet (state, (i, dest, r))
                | M.RhsCont r           => cont (state, (i, dest, r))
                | M.RhsObjectGetKind r  => objectGetKind (state, (i, dest, r))
                | M.RhsThunkMk r        => thunkMk (state, (i, dest, r))
                | M.RhsThunkInit r      => thunkInit (state, (i, dest, r))
	        | M.RhsThunkGetFv r     => thunkGetFv (state, (i, dest, r))
                | M.RhsThunkValue r     => thunkValue (state, (i, dest, r))
                | M.RhsThunkGetValue r  => thunkGetValue (state, (i, dest, r))
                | M.RhsThunkSpawn r     => thunkSpawn (state, (i, dest, r))
                | M.RhsPFunctionMk r    => pFunctionMk (state, (i, dest, r))
                | M.RhsPFunctionInit r  => pFunctionInit (state, (i, dest, r))
                | M.RhsPFunctionGetFv r => pFunctionGetFv (state, (i, dest, r))
                | M.RhsPSetNew r        => pSetNew (state, (i, dest, r))
                | M.RhsPSetGet r        => pSetGet (state, (i, dest, r))
                | M.RhsPSetCond r       => pSetCond (state, (i, dest, r))
                | M.RhsPSetQuery r      => pSetQuery (state, (i, dest, r))
                | M.RhsPSum r           => pSum (state, (i, dest, r))
                | M.RhsPSumProj r       => pSumProj (state, (i, dest, r))
        in r
        end

    val reduce = globalize or simplify
  end (* structure InstructionR *)

  structure InstrR : REDUCE =
  struct
    type t = I.iInstr

    val reduce = 
     fn (s as (d, imil, ws), i) => 
        let
          val t = 
             case IInstr.getMil (imil, i)
              of IMil.MDead       => Try.failure ()
               | IMil.MTransfer t => TransferR.reduce (s, (i, t))
               | IMil.MLabel l    => LabelR.reduce (s, (i, l))
               | IMil.MInstr mi   => InstructionR.reduce (s, (i, mi))
       in t
       end

  end (* structure InstrR *)

  structure ItemR = 
  struct

    val reduce = 
     fn (d, imil, ws, i, uses) =>
       let
         val doOne = 
          fn (getUsedBy, reduce) =>
          fn obj => 
             let
               val usedByI = getUsedBy (imil, obj)
               val res = 
                   case reduce ((d, imil, ws), obj)
                    of SOME is => 
                       let
                         val () = WS.addItems (ws, usedByI)
                         val () = WS.addUses (ws, uses)
                         val () = List.foreach (is, fn i => WS.addItem (ws, i))
                       in true
                       end
                     | _ => false
             in res
             end

         val res = 
             case i
              of IMil.ItemGlobal g    => doOne (IGlobal.getUsedBy, GlobalR.reduce) g
               | IMil.ItemInstr i  => doOne (IInstr.getUsedBy, InstrR.reduce) i
               | IMil.ItemFunc f   => doOne (IFunc.getUsedBy, FuncR.reduce) f
       in res
       end


  end (* structure ItemR *)


  val rec killItem = 
   fn (d, imil, ws, i, inits) =>
       let
         val usedByI = Item.getUsedBy (imil, i)
         val () = Vector.foreach (inits, 
                                  (fn u => killUse (d, imil, ws, u)))
         val () = Click.dce d
         val () = Item.delete (imil, i)
         val () = WS.addItems (ws, usedByI)
       in ()
       end
   and rec killUse = 
    fn (d, imil, ws, u) =>
       let
         val inits = Vector.new0 ()
         val () = (case u
                    of I.UseInstr i => 
                       killItem (d, imil, ws, I.ItemInstr i, inits) 
                     | I.UseGlobal g => 
                       killItem (d, imil, ws, I.ItemGlobal g, inits)
                     | I.Used => ())
       in ()
       end

  val deadCode = 
   fn (d, imil, ws, i, uses) => 
      let
        val {inits, others} = Item.splitUses' (imil, i, uses)
        val dead = Vector.isEmpty others
        val ok = Effect.subset(Item.fx (imil, i), Effect.ReadOnly)
        val kill = dead andalso ok
        val () = if kill then killItem (d, imil, ws, i, inits) else ()
      in kill
      end

  val postReduction = 
   fn (d, imil) => 
      let
        val () = if checkIr d then IMil.T.check imil else ()
        val () = if showIr d then MilLayout.printGlobalsOnly (PD.getConfig d, IMil.T.unBuild imil) else ()
      in ()
      end

  val simplify = 
   fn (d, imil, ws) => 
      let
        val sEach = showEach d
        val sReductions = showReductions d
        val layout = 
         fn (s, i) => if sEach orelse sReductions then
                        Layout.seq [Layout.str s, Item.layout (imil, i)]
                      else
                        Layout.empty
        val rec loop = 
         fn () =>
            case WS.chooseWork ws
             of SOME i => 
                let
                  val () = if sEach then LayoutUtils.printLayout (layout ("Trying: ", i)) else ()
                  val l1 = layout ("R: ", i)
                  val uses = Item.getUses (imil, i)
                  val reduced = deadCode (d, imil, ws, i, uses) orelse ItemR.reduce (d, imil, ws, i, uses)
                  val () = 
                      if (sReductions andalso reduced) then
                        LayoutUtils.printLayout l1
                      else ()
                  val () = 
                      if reduced then
                        let
                          val () = if sReductions then LayoutUtils.printLayout (layout ("==> ", i)) else ()
                          val () = postReduction (d, imil)
                        in ()
                        end
                      else ()
                in loop ()
                end
              | NONE => ()
      in loop ()
      end



  (* Eliminate global objects and functions that are not reachable from the entry point.
   * Make a graph with a node for each global object or function, and with edges to each 
   * global object or function from every other global object or function which contains a use
   * of it.  All the nodes that are unreachable in this graph (starting at the entry function)
   * are dead and can be eliminated.
   *)
  val unreachableCode = 
   fn (d, imil) =>
      let
        datatype global = Func of I.iFunc | Object of I.iGlobal
        val graph = IPLG.new ()
        val nodes = IVD.empty ()
        val varToNode = fn v => Option.valOf (IVD.lookup(nodes, v))
        val nodeToGlobal = IPLG.Node.getLabel
        val useToNode = 
            fn u => 
               (case u
                 of I.Used => NONE
                  | I.UseInstr i => 
                    let
                      val iFunc = IInstr.getIFunc (imil, i)
                      val fname = IFunc.getFName (imil, iFunc)
                      val node = varToNode fname
                    in SOME node
                    end
                  | I.UseGlobal g => 
                    let
                      val v = IGlobal.getVar (imil, g)
                      val node = varToNode v
                    in SOME node
                    end)

        val fNodes = 
            let
              val iFuncs = Enumerate.T.funcs imil
              val addIFuncNode = 
               fn iFunc => 
                  let
                    val v = IFunc.getFName (imil, iFunc)
                    val n = IPLG.newNode (graph, (Func iFunc))
                    val () = IVD.insert (nodes, v, n)
                    val uses = IFunc.getUses (imil, iFunc)
                  in (n, uses)
                  end
              val fNodes = List.map (iFuncs, addIFuncNode)
            in fNodes
            end
        val gNodes = 
            let
              val objects = Enumerate.T.globals imil
              val addGlobalNode = 
               fn g => 
                  case IGlobal.getMil (imil, g)
                   of I.GDead => NONE
                    | I.GGlobal (v, _) => 
                      let
                        val n = IPLG.newNode (graph, (Object g))
                        val () = IVD.insert (nodes, v, n)
                        val uses = IGlobal.getUses (imil, g)
                      in SOME (n, uses)
                      end
              val gNodes = List.keepAllMap (objects, addGlobalNode)
            in gNodes
            end
        val () = 
            let
              val nodes = fNodes@gNodes
              val addEdges = 
               fn (n1, uses) => 
                  let
                    val addEdge = 
                     fn u => 
                        case useToNode u
                         of SOME n2 => ignore (IPLG.addEdge(graph, n2, n1, ()))
                          | NONE => ()
                    val () = Vector.foreach (uses, addEdge)
                  in ()
                  end
              val () = List.foreach (nodes, addEdges)
            in ()
            end
        val () = 
            let
              val entry = I.T.getEntry imil
              val dead = IPLG.unreachable (graph, varToNode entry)
              val killNode = 
               fn n => 
                  let
                    val () = Click.unreachable d
                    val () =
                        (case nodeToGlobal n
                          of Func f => IFunc.delete (imil, f)
                           | Object g => IGlobal.delete (imil, g))
                  in ()
                  end
              val () = List.foreach (dead, killNode)
            in ()
            end
      in ()
      end

  val postPhase = 
   fn (d, imil) => 
      let
        val () = if statPhase d then Stats.report (PD.getStats d) else ()
        val () = if checkPhase d then IMil.T.check imil else ()
        val () = if showPhase d then MilLayout.printGlobalsOnly (PD.getConfig d, IMil.T.unBuild imil) else ()
      in ()
      end

  val doPhase = 
   fn (skip, f, name) =>
   fn (d, imil) => 
      if skip d then
        Chat.log1 (d, "Skipping "^name)
      else
        let
          val () = Chat.log1 (d, "Doing "^name)
          val () = f (d, imil)
          val () = Chat.log1 (d, "Done with "^name)
          val () = postPhase (d, imil)
        in ()
        end

  val skip = 
   fn name => 
   fn (d, imil) => 
        Chat.log1 (d, "Skipping "^name)


  val trimCfgs = fn (d, imil, ws) => ()

  val doUnreachable = doPhase (skipUnreachable, unreachableCode, "unreachable object elimination")
  val doSimplify = 
   fn ws => doPhase (skipSimplify, fn (d, imil) => simplify (d, imil, ws), "simplification")
(*val doCfgSimplify = 
   fn ws => doPhase (skipCfg, fn (d, imil) => trimCfgs (d, imil, ws), "cfg simplification")
  val doEscape = doPhase (skipEscape, SimpleEscape.optimize, "closure escape analysis")
  val doRecursive = doPhase (skipRecursive, analyizeRecursive, "recursive function analysis") *)

  val doCfgSimplify = fn ws => skip "cfg simplification"
  val doEscape = skip "closure escape analysis"
  val doRecursive = skip "recursive function analysis"
      
  val doIterate = 
   fn (d, imil) => 
      let
        val ws = WS.new ()
        val () = WS.addAll (ws, imil)
        val step = 
         fn () =>
            let
              val () = doSimplify ws (d, imil)
              val () = doCfgSimplify ws (d, imil)
            in ()
            end

        val () = step ()
        val () = 
            if noIterate d then 
              step () 
            else 
              while WS.hasWork ws do step ()
      in ()
      end

  val optimize = 
   fn (d, imil) =>
      let
        val () = doUnreachable (d, imil)
        val () = doIterate (d, imil)
        val () = doEscape (d, imil)
        val () = doRecursive (d, imil)
      in ()
      end

  val program = 
   fn (d, imil) =>
      let
        val () = optimize (d, imil)
        val () = PD.report (d, passname)
      in ()
      end

  val stats = Click.stats (*@ MilFunKnown.stats @ SimpleEscape.stats*)
  val description =
      {name        = passname,
       description = "Mil simplifier",
       inIr        = BothMil.irHelpers,
       outIr       = BothMil.irHelpers,
       mustBeAfter = [],
       stats       = Click.stats}

  val associates = {controls  = [],
                    debugs    = debugs (*@ MilFunKnown.debugs*),
                    features  = features,
                    subPasses = []}

  val pass =
      Pass.mkOptPass (description, associates,
                      BothMil.mkIMilPass (program o Utils.flip2))

end