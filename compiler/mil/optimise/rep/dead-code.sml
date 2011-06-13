(* The Intel P to C/Pillar Compiler *)
(* COPYRIGHT_NOTICE_1 *)

signature MIL_REP_DCE = 
sig
  val pass : (BothMil.t, BothMil.t) Pass.t
end

structure MilRepDce :> MIL_REP_DCE = 
struct
  val passname = "MilRepDce"
  val fail = 
   fn (fname, msg) => Fail.fail ("dead-code.sml", fname, msg)

  structure M = Mil
  structure MU = MilUtils
  structure MFV = MilFreeVars
  structure VS = Mil.VS
  structure LS = Mil.LS
  structure VD = Mil.VD
  structure ID = IntDict
  structure PD = PassData
  structure MT = MilType
  structure MTT = MT.Type
  structure FG = MilRepFlowGraph
  structure MRS = MilRepSummary
  structure MRN = MilRepNode
  structure MRO = MilRepObject
  structure MRB = MilRepBase
  structure I = Identifier
  structure STM = I.Manager

  structure Chat = ChatF (struct 
                            type env = PD.t
                            val extract = PD.getConfig
                            val name = passname
                            val indent = 2
                          end)


  val (noDceF, noDce) =
      PD.mkFeature (passname ^ ":no-dce", "disable dead code elimination")

  val (statPhasesF, statPhases) = 
      PD.mkLogFeature (passname, passname ^ ":stat-phases", "Show stats between each phase", 2)

  val mkDebug = 
   fn (tag, description) => PD.mkDebug (passname^":"^tag, description)

  val (debugPassD, debugPass) =
      mkDebug ("debug", "Debug rep dce according to debug level")

  val mkLevelDebug = 
   fn (tag, description, level) => PD.mkLevelDebug (passname, passname^":"^tag, description, level, debugPass)

  val (checkPhasesD, checkPhases) =
      mkLevelDebug ("check-phases", "Check IR between each phase", 0)

  val (showPhasesD, showPhases) =
      mkLevelDebug ("show-phases", "Show IR between each phase", 0)

  val (showD, show) = 
      mkLevelDebug ("show-dce", "Show dce analysis", 1)

  val (showAnalysisD, showAnalysis) =
      mkLevelDebug ("show-analysis", "Show analysis results", 1)

  val (skipReconstructionD, skipReconstruction) =
      mkDebug ("skip-reconstruction", "Don't reconstruct types")

  val (annotateProgramD, annotateProgram) =
      mkDebug ("annotate", "Annotate program variables with class")

  val debugs = [annotateProgramD, checkPhasesD, debugPassD, showAnalysisD, showD, showPhasesD, 
                skipReconstructionD]

  val features = [noDceF, statPhasesF]

  structure Click = 
  struct
    val stats = []
    val {stats, click = dce} = PD.clicker {stats = stats, passname = passname, 
                                           name = "Dead", desc = "Dead objects/instructions eliminated"}
  end   (*  structure Click *)

  val stats = Click.stats

  structure Dce = 
  struct

    val skip = noDce

    structure SE1 = 
    struct
      datatype state = S of {summary : MRS.summary,
                             flowgraph : bool FG.t}

      datatype env = E of {pd : PD.t, current : Mil.variable option}

      val getSummary = fn (S {summary, ...}) => summary
      val getFlowGraph = fn (S {flowgraph, ...}) => flowgraph
      val getPd = fn (E {pd, ...}) => pd
      val getCurrent = fn (E {current, ...}) => 
                          (case current 
                            of SOME f => f
                             | NONE => fail ("getCurrent", "Not in a function"))
      val setCurrent = fn (E {current, pd}, v) => E {current = SOME v, pd = pd}
      val getConfig = PD.getConfig o getPd
    end

    structure Analyze1 =
    MilAnalyseF(struct
                  type state = SE1.state
                  type env = SE1.env
                  val config = SE1.getConfig
                  val indent = 2
                  val externBind = NONE
                  val variableBind = NONE
                  val labelBind = NONE
                  val variableUse = NONE
                  val analyseJump = NONE
                  val analyseCut = NONE
                  val analyseConstant = NONE
                  val analyseInstruction' = 
                   fn (s, e, M.I {dests, n, rhs}) => 
                       let
                         val summary = SE1.getSummary s
                         val fg = SE1.getFlowGraph s
                         val fvs = MFV.rhs (SE1.getConfig e, rhs)
                         val live =
                          fn v => FG.add (fg, MRS.variableNode (summary, v), true)
                         val keep = fn () => VS.foreach (fvs, live)
                         (* This function keeps things used in effectful instructions live, if called *)
                         val fx = 
                          fn () => 
                             if Effect.subset(MU.Rhs.fx (SE1.getConfig e, rhs), Effect.ReadOnly) then () 
                             else 
                               keep ()
                         (* This function introduces data dependencies from free variables to dests, if called *)
                         val data = 
                          fn () => 
                             let
                               val targets = Vector.map (dests, fn v => MRS.variableNode (summary, v))
                               val edge = 
                                fn v => 
                                   let
                                     val from = MRS.variableNode (summary, v)
                                   in Vector.foreach (targets, fn to => FG.addEdge (fg, from, to))
                                   end
                             in VS.foreach (fvs, edge)
                             end
                         val both = fx o data
                         val tupleDeps = 
                          fn () =>
                             let
                               val id = MU.Id.I n
                               val () = 
                                   (case MRS.iInfo (summary, id)
                                     of MRB.IiMetaData {pok, fixed, array} => 
                                        (case array
                                          of SOME (i, n) => FG.addEdge (fg, Vector.sub (fixed, i), n)
                                           | NONE        => ())
                                      | _ => fail ("tupleDeps", "Bad metadata"))
                             in ()
                             end
                         val tupleSetDeps = 
                          fn M.TF {tupDesc, tup, field} => 
                             let
                               val id = MU.Id.I n
                               val {fixed, array} = 
                                   (case MRS.iInfo (summary, id)
                                     of MRB.IiTupleDescriptor r => r
                                      | _ => fail ("tupleSetDeps", "Bad metadata"))
                               val doFvs = 
                                fn n => VS.foreach (fvs, fn v => FG.addEdge (fg, MRS.variableNode (summary, v), n))
                               val doVariable = 
                                fn () =>
                                   case array
                                    of SOME n => doFvs n
                                     | NONE   => keep ()
                               val doFixed =  
                                fn i => 
                                   if i >= 0 andalso i < Vector.length fixed then
                                     doFvs (Vector.sub (fixed, i))
                                   else
                                     doVariable ()
                               val () = 
                                   case field
                                    of M.FiFixed i       => doFixed i
                                     | M.FiVariable _    => doVariable ()
                                     | M.FiVectorFixed r => 
                                       let
                                         val {index, descriptor, ...} = r
                                         val count = MU.Prims.Utils.VectorDescriptor.elementCount descriptor
                                       in Utils.Iterate.foreach (index, fn i => i + 1, fn i => i < index + count, doFixed)
                                       end
                                     | M.FiVectorVariable _ => doVariable ()
                             in ()
                             end
                         val setCondDeps = 
                          fn {bool, ofVal} => 
                             case bool
                              of M.SVariable v => 
                                 let
                                   val n = MRS.variableNode (summary, v)
                                 in Vector.foreach (dests, fn v => FG.addEdge (fg, n, MRS.variableNode (summary, v)))
                                 end
                               | _ => ()
                         val () = 
                             case rhs
                              of M.RhsSimple s         => ()
                               | M.RhsPrim _           => both ()
                               | M.RhsTuple r          => tupleDeps ()
                               | M.RhsTupleSub tf      => data ()
                               | M.RhsTupleSet r       => tupleSetDeps (#tupField r)
                               | M.RhsTupleInited r    => tupleDeps ()
                               | M.RhsIdxGet _         => data ()
                               | M.RhsCont _           => ()
                               | M.RhsObjectGetKind _  => data ()
                               | M.RhsThunkMk _        => ()
                               | M.RhsThunkInit r      => Option.foreach (#code r, live)
                               | M.RhsThunkGetFv r     => data ()
                               | M.RhsThunkValue r     => ()
                               | M.RhsThunkGetValue _  => data ()
                               | M.RhsThunkSpawn _     => fx ()
                               | M.RhsClosureMk _      => ()
                               | M.RhsClosureInit r    => Option.foreach (#code r, live)
                               | M.RhsClosureGetFv r   => data ()
                               | M.RhsPSetNew _        => ()
                               | M.RhsPSetGet _        => data ()
                               | M.RhsPSetCond r       => setCondDeps r
                               | M.RhsPSetQuery _      => data ()
                               | M.RhsPSum _           => ()
                               | M.RhsPSumProj _       => data ()

                       in e
                       end
                  val analyseInstruction = SOME analyseInstruction'
                  val analyseTransfer' = 
                   fn (s, e, t) => 
                      let 
                        val summary = SE1.getSummary s
                        val fg = SE1.getFlowGraph s
                        val liveN = fn n => FG.add (fg, n, true)
                        val live = fn v => liveN (MRS.variableNode (summary, v))
                        val liveO = 
                         fn oper => 
                            case oper
                             of M.SVariable v => live v
                              | _             => ()
                        val () = 
                            (case t
                              of M.TGoto _      => ()
                               | M.TCase r      => liveO (#on r)
                               | M.TInterProc r => 
                                 let
                                   val {callee, ret, fx} = r
                                   val fv = 
                                       case callee
                                        of M.IpCall {call, ...} => 
                                           (case call
                                             of M.CCode r          => #ptr r
                                              | M.CClosure r       => #cls r
                                              | M.CDirectClosure r => #code r)
                                         | M.IpEval {eval, ...} => 
                                           (case eval 
                                             of M.EThunk r       => #thunk r
                                              | M.EDirectThunk r => #thunk r)
                                   val fNode = MRS.variableNode (summary, fv)
                                   val () = 
                                       if MU.Cuts.hasCuts (MU.Return.cuts ret) then
                                         liveN fNode
                                       else () 
                                   val destNodes = 
                                       case ret
                                        of M.RNormal {rets, ...} => 
                                           Vector.map (rets, fn v => MRS.variableNode (summary, v))
                                         | M.RTail _             => 
                                           (case MRS.iInfo (summary, MU.Id.G (SE1.getCurrent e))
                                             of MRB.IiCode {returns, ...} => returns
                                              | _ => fail ("analyseTransfer'", "Bad function information"))
                                   val () = 
                                       if Effect.subset(fx, Effect.ReadOnly) then 
                                         Vector.foreach (destNodes, fn n => FG.addEdge (fg, fNode, n))
                                       else 
                                         liveN fNode
                                 in ()
                                 end
                               | M.TReturn _    => () 
                               | M.TCut r       => live (#cont r)
                               | M.THalt p      => liveO p
                               | M.TPSumCase r  => liveO (#on r))
                      in e
                      end
                  val analyseTransfer = SOME analyseTransfer'
                  val analyseBlock = NONE
                  val analyseGlobal' = 
                   fn (s, e, v, g) => 
                       let
                         val summary = SE1.getSummary s
                         val fg = SE1.getFlowGraph s
                         val liveN = fn n => FG.add (fg, n, true)
                         val live = fn v => liveN (MRS.variableNode (summary, v))
                         val e = 
                             (case g
                               of M.GCode r                        => 
                                  let
                                    val M.F {cc, ...} = r
                                    val doFvs = 
                                     fn (v, fvs) => 
                                        let
                                          val n = MRS.variableNode (summary, v)
                                          val add = fn v => FG.addEdge (fg, n, MRS.variableNode (summary, v))
                                          val () = Vector.foreach (fvs, add)
                                        in ()
                                        end
                                    val () = case cc
                                              of M.CcCode => ()
                                               | M.CcClosure {cls, fvs} => doFvs (cls, fvs)
                                               | M.CcThunk {thunk, fvs} => doFvs (thunk, fvs)
                                    val e = SE1.setCurrent (e, v)
                                  in e
                                  end
                                | M.GClosure {code = SOME f, ...}  => let val () = live f in e end
                                | M.GTuple {mdDesc, inits}         => 
                                  let
                                    val id = MU.Id.G v
                                    val () = 
                                        (case MRS.iInfo (summary, id)
                                          of MRB.IiMetaData {pok, fixed, array} => 
                                             (case array
                                               of SOME (i, n) => FG.addEdge (fg, Vector.sub (fixed, i), n)
                                                | NONE        => ())
                                           | _ => fail ("analyseGlobal'", "Bad metadata"))
                                  in e
                                  end
                                | _                                => e)
                       in e
                       end
                  val analyseGlobal = SOME analyseGlobal'
                end)

    structure SE2 = 
    struct
      datatype state = S of {summary : MRS.summary,
                             flowgraph : bool FG.t}

      datatype env = E of {pd : PD.t}

      val getSummary = fn (S {summary, ...}) => summary
      val getFlowGraph = fn (S {flowgraph, ...}) => flowgraph
      val getPd = fn (E {pd, ...}) => pd
      val getConfig = PD.getConfig o getPd
    end

    structure Analyze2 =
    MilAnalyseF(struct
                  type state = SE2.state
                  type env = SE2.env
                  val config = SE2.getConfig
                  val indent = 2
                  val externBind = NONE
                  val variableBind = NONE
                  val labelBind = NONE
                  val variableUse = NONE
                  val analyseJump = NONE
                  val analyseCut = NONE
                  val analyseConstant = NONE
                  val analyseInstruction' = 
                   fn (s, e, M.I {dests, n, rhs}) => 
                       let
                         val summary = SE2.getSummary s
                         val fg = SE2.getFlowGraph s
                         val cmpd = 
                          fn oper => 
                             (case oper
                               of M.SVariable v => FG.add (fg, MRS.variableNode (summary, v), true)
                                | _             => ())
                         val () = 
                             case rhs
                              of M.RhsPrim {prim, args, ...} => 
                                 (case prim
                                   of Mil.Prims.Prim Mil.Prims.PPtrEq => Vector.foreach (args, cmpd)
                                    | _ => ())
                               | _ => ()
                       in e
                       end
                  val analyseInstruction = SOME analyseInstruction'
                  val analyseTransfer' = 
                   fn (s, e, t) => 
                      let 
                        val summary = SE2.getSummary s
                        val fg = SE2.getFlowGraph s
                         val cmpd = 
                          fn oper => 
                             (case oper
                               of M.SVariable v => FG.add (fg, MRS.variableNode (summary, v), true)
                                | _             => ())
                        val () = 
                            case t
                             of M.TCase r      => cmpd (#on r)
                              | _              => ()
                      in e
                      end
                  val analyseTransfer = SOME analyseTransfer'
                  val analyseBlock = NONE
                  val analyseGlobal = NONE
                end)

    structure SE3 = 
    struct
      datatype state = S of {summary : MRS.summary,
                             flowgraph : bool FG.t,
                             compared : bool FG.t}

      datatype env = E of {pd : PD.t}

      val getSummary = fn (S {summary, ...}) => summary
      val getFlowGraph = fn (S {flowgraph, ...}) => flowgraph
      val getCompared = fn (S {compared, ...}) => compared
      val getPd = fn (E {pd, ...}) => pd
      val getConfig = PD.getConfig o getPd
    end

    structure Analyze3 =
    MilAnalyseF(struct
                  type state = SE3.state
                  type env = SE3.env
                  val config = SE3.getConfig
                  val indent = 2
                  val externBind = NONE
                  val variableBind = NONE
                  val labelBind = NONE
                  val variableUse = NONE
                  val analyseJump = NONE
                  val analyseCut = NONE
                  val analyseConstant = NONE
                  val doTuple = 
                   fn (s, e, v, id, md) => 
                      let
                         val summary = SE3.getSummary s
                         val fg = SE3.getFlowGraph s
                         val compared = SE3.getCompared s
                         val live = FG.query (fg, MRS.variableNode (summary, v)) 
                         val cmpd = FG.query (compared, MRS.variableNode (summary, v))
                      in
                        if live andalso cmpd then
                          let
                            val {fixed = fixedN, array = arrayN, ...} = 
                                case MRS.iInfo (summary, id)
                                 of MRB.IiMetaData r => r
                                  | _                => fail ("doTuple", "Bad metadata")
                            val M.MDD {fixed, array, ...} = md
                            val check = 
                             fn (node, fd) => 
                                let
                                  val live = FG.query (fg, node)
                                  val mutable = MU.FieldDescriptor.mutable fd
                                in live andalso mutable
                                end
                            val ok = 
                                Utils.Vector.exists2 (fixedN, fixed, check) orelse
                                (case (arrayN, array)
                                  of (SOME (_, n), SOME (_, fd)) => check (n, fd)
                                   | (NONE, NONE)                => false
                                   | _                           => fail ("doTuple", "Mismatched metadata"))
                            val mark = 
                             fn n => FG.add (fg, n, true)
                            val () = 
                                if ok then ()
                                else 
                                  case (Vector.index (fixed, MU.FieldDescriptor.mutable), arrayN, array)
                                   of (SOME i, _, _) => mark (Vector.sub (fixedN, i))
                                    | (_, SOME (_, n), SOME (_, fd))  => 
                                      if MU.FieldDescriptor.mutable fd then mark n 
                                      else ()
                                    | _ => ()
                          in ()
                          end
                        else ()
                      end
                  val analyseInstruction' = 
                   fn (s, e, M.I {dests, n, rhs}) => 
                       let
                         val () = 
                             case rhs
                              of M.RhsTuple r => doTuple (s, e, Vector.sub (dests, 0), MU.Id.I n, #mdDesc r)
                               | _ => ()
                       in e
                       end
                  val analyseInstruction = SOME analyseInstruction'
                  val analyseTransfer = NONE
                  val analyseBlock = NONE
                  val analyseGlobal' = 
                   fn (s, e, v, g) => 
                       let
                         val () = 
                             (case g
                               of M.GTuple r  => doTuple (s, e, v, MU.Id.G v, #mdDesc r)
                                | _           => ())
                       in e
                       end
                  val analyseGlobal = SOME analyseGlobal'
                end)

    structure Rewrite = 
    struct

      datatype state = S of {stm : M.symbolTableManager, summary : MRS.summary, fg : bool FG.t}
      datatype env = E of {pd : PD.t, dead : VS.t, thunk : M.fieldKind option}

      val getStm = fn (S {stm, ...}) => stm
      val getSummary = fn (S {summary, ...}) => summary
      val getFlowGraph = fn (S {fg, ...}) => fg
      val getPd = fn (E {pd, ...}) => pd
      val getConfig = PD.getConfig o getPd
      val getDead = fn (E {dead, ...}) => dead
      val getThunk = fn (E {thunk, ...}) => thunk
      val setThunk = fn (E {pd, dead, thunk = _}, thunk ) =>  E {pd = pd, dead = dead, thunk = thunk}

      structure MS = MilStream

      val variableIsDead = 
       fn (state, env, v) => VS.member (getDead env, v)

      val killVariablesV = 
       fn (state, env, vs) => Vector.keepAll (vs, fn v => not (variableIsDead (state, env, v)))

      val label = 
       fn (state, env, l, vs) => 
          let
            val vs = killVariablesV (state, env, vs)
            val so = SOME (l, vs, MS.empty)
          in (env, so)
          end

      val fieldDefault = 
       fn (state, env, fk) => 
          let
            val c = 
                case fk
                 of M.FkRef => 
                    let
                      (* This is used in places that needed to be distinguished from null *)
                      val () = if MU.HeapModel.validRefConstant (getConfig env, IntInf.one) then ()
                               else fail ("instr", "Need a valid non-null heap constant")
                    in M.CRef IntInf.one
                    end
                  | M.FkBits fs => 
                    let
                      val sz = MU.FieldSize.toIntArbSz fs
                      val typ = IntArb.T (sz, IntArb.Unsigned)
                      val i = IntArb.fromIntInf (typ, IntInf.zero)
                    in M.CIntegral i
                    end
                  | M.FkFloat  => M.CFloat 0.0
                  | M.FkDouble => M.CDouble 0.0
          in M.SConstant c
          end
          
      val instr = 
       fn (state, env, i as M.I {dests, n, rhs}) => 
          let
            val summary = getSummary state
            val fg = getFlowGraph state
            val fieldDefault = fn fk => fieldDefault (state, env, fk)
            val dead = fn v => variableIsDead (state, env, v)
            val live = not o dead
            val deadV = fn vs => Vector.forall (vs, dead)
            val liveV = not o deadV
            val kill = fn () => 
                          let
                            val () = Click.dce (getPd env) 
                          in SOME MS.empty
                          end
            val keep = fn () => NONE
            val keepIfLive = 
             fn v => if dead v then kill () else keep ()
            val keepIfAnyLive = 
             fn vs => if List.forall (vs, dead) then kill () else keep ()
            val keepIfAnyLiveV = 
             fn vs => if Vector.forall (vs, dead) then kill () else keep ()
            val toVar = 
             fn oper => case oper
                         of M.SVariable v => v
                          | M.SConstant _ => fail ("instr", "Not in named form")
            val toVarV = fn v => Vector.map (v, toVar)
            val liveO = live o toVar
            val deadO = not o liveO
            val keepIfLiveO = keepIfLive o toVar
            val adjustIndex = 
             fn (i, nodes) => 
                let
                  val rec loop = 
                   fn (j, idx) => 
                      if j < i andalso j < Vector.length nodes then 
                        if FG.query (fg, Vector.sub (nodes, j)) then
                          loop (j + 1, idx + 1)
                        else
                          loop (j + 1, idx)
                      else 
                        idx
                in loop (0, 0)
                end
            val tupleField = 
             fn M.TF {tupDesc, tup, field} => 
                let
                  val {fixed = fixedN, array = arrayN} = 
                      case MRS.iInfo (summary, MU.Id.I n)
                       of MRB.IiTupleDescriptor r => r
                        | _                       => fail ("tupleField", "Bad tuple descriptor")
                  val doFixed = fn i => adjustIndex (i, fixedN)
                  val field = case field
                               of M.FiFixed i          => M.FiFixed (doFixed i)
                                | M.FiVariable _       => field
                                | M.FiVectorFixed r    => M.FiVectorFixed {descriptor = #descriptor r, 
                                                                           mask = #mask r, 
                                                                           index = doFixed (#index r)}
                                | M.FiVectorVariable _ => field
                in M.TF {tupDesc = tupDesc, tup = tup, field = field}
                end
            val thunkGetFv = 
             fn {typ, fvs, thunk, idx} => 
                let
                  val nodes = 
                      case MRS.iInfo (summary, MU.Id.I n)
                       of MRB.IiThunk {typ, fvs} => fvs
                        | _                      => fail ("thunkGetFv", "Bad descriptor")
                  val idx = adjustIndex (idx, nodes)
                  val r = {typ = typ, fvs = fvs, thunk = thunk, idx = idx}
                in r
                end
            val closureGetFv = 
             fn {fvs, cls, idx} => 
                let
                  val nodes = 
                      case MRS.iInfo (summary, MU.Id.I n)
                       of MRB.IiClosure fvs => fvs
                        | _                 => fail ("closureGetFv", "Bad descriptor")
                  val idx = adjustIndex (idx, nodes)
                  val r = {fvs = fvs, cls = cls, idx = idx}
                in r
                end
            val replace = fn rhs => SOME (MS.instruction (M.I {dests = dests, n = n, rhs = rhs}))

            val so = 
                case rhs
                 of M.RhsSimple s         => keepIfAnyLiveV dests
                  | M.RhsPrim _           => if Effect.subset(MU.Rhs.fx (getConfig env, rhs), Effect.ReadOnly) then
                                               keepIfAnyLiveV dests
                                             else
                                               keep ()
                  | M.RhsTuple r          => if deadV dests then kill () else 
                                             let
                                               val {mdDesc, inits} = r
                                               val inits = Vector.keepAll (inits, liveO)
                                               val rhs = M.RhsTuple {mdDesc = mdDesc, inits = inits}
                                             in replace rhs
                                             end
                  | M.RhsTupleSub tf      => if deadV dests then kill () else 
                                             let
                                               val tf = tupleField tf
                                               val rhs = M.RhsTupleSub tf
                                             in replace rhs
                                             end
                  | M.RhsTupleSet r       => if deadO (#ofVal r) then kill () else
                                             let
                                               val {tupField, ofVal} = r
                                               val tupField = tupleField tupField
                                               val rhs = M.RhsTupleSet {tupField = tupField, ofVal = ofVal}
                                             in replace rhs
                                             end
                  | M.RhsTupleInited r    => keepIfLive (#tup r)
                  | M.RhsIdxGet _         => keepIfAnyLiveV dests
                  | M.RhsCont _           => keepIfAnyLiveV dests
                  | M.RhsObjectGetKind _  => keepIfAnyLiveV dests
                  | M.RhsThunkMk _        => keepIfAnyLiveV dests
                  | M.RhsThunkInit r      => if deadV dests andalso Option.forall (#thunk r, dead) then kill () else
                                             let
                                               val {typ, thunk, fx, code, fvs} = r
                                               val fvs = Vector.keepAll (fvs, fn (fk, oper) => liveO oper)
                                               val rhs = M.RhsThunkInit {typ = typ, 
                                                                         thunk = thunk, 
                                                                         fx = fx, 
                                                                         code = code, 
                                                                         fvs = fvs}
                                             in replace rhs
                                             end
                  | M.RhsThunkGetFv r     => if deadV dests then kill () else 
                                             let
                                               val r = thunkGetFv r
                                               val rhs = M.RhsThunkGetFv r
                                             in replace rhs
                                             end
                  | M.RhsThunkValue r     => if deadV dests andalso Option.forall (#thunk r, dead) then kill () else
                                             if liveO (#ofVal r) then keep () else
                                             let
                                               val {typ, thunk, ofVal} = r
                                               val oper = fieldDefault typ
                                               val rhs = M.RhsThunkValue {typ = typ, thunk = thunk, ofVal = oper}
                                             in replace rhs
                                             end
                  | M.RhsThunkGetValue _  => keepIfAnyLiveV dests
                  | M.RhsThunkSpawn r     => keepIfLive (#thunk r)
                  | M.RhsClosureMk _      => keepIfAnyLiveV dests
                  | M.RhsClosureInit r    => if deadV dests andalso Option.forall (#cls r, dead) then kill () else
                                             let
                                               val {cls, code, fvs} = r
                                               val fvs = Vector.keepAll (fvs, fn (fk, oper) => liveO oper)
                                               val rhs = M.RhsClosureInit {cls = cls, code = code, fvs = fvs}
                                             in replace rhs
                                             end
                  | M.RhsClosureGetFv r   => if deadV dests then kill () else 
                                             let
                                               val r = closureGetFv r
                                               val rhs = M.RhsClosureGetFv r
                                             in replace rhs
                                             end
                  | M.RhsPSetNew p        => if deadV dests then kill () else
                                             if liveO p then keep () else
                                             let
                                               val p = fieldDefault M.FkRef
                                               val rhs = M.RhsPSetNew p
                                             in replace rhs
                                             end
                  | M.RhsPSetGet _        => keepIfAnyLiveV dests
                  | M.RhsPSetCond r       => if deadV dests then kill () else
                                             if liveO (#ofVal r) then keep () else
                                             let
                                               val {bool, ...} = r
                                               val ofVal = fieldDefault M.FkRef
                                               val rhs = M.RhsPSetCond {bool = bool, ofVal = ofVal}
                                             in replace rhs
                                             end
                  | M.RhsPSetQuery _      => keepIfAnyLiveV dests
                  | M.RhsPSum r           => if deadV dests then kill () else
                                             if liveO (#ofVal r) then keep () else
                                             let
                                               val {typ, ofVal, tag} = r
                                               val ofVal = fieldDefault typ
                                               val rhs = M.RhsPSum {typ = typ, ofVal = ofVal, tag = tag}
                                             in replace rhs
                                             end
                  | M.RhsPSumProj _       => keepIfAnyLiveV dests
          in (env, so)
          end

      val transfer =
       fn (state, env, t) => 
          let
            val fieldDefault = fn fk => fieldDefault (state, env, fk)
            val dead = fn v => variableIsDead (state, env, v)
            val live = not o dead
            val deadV = fn vs => Vector.forall (vs, dead)
            val liveV = not o deadV
            val keep = fn () => (env, NONE)
            val toVar = 
             fn oper => case oper
                         of M.SVariable v => v
                          | M.SConstant _ => fail ("instr", "Not in named form")
            val toVarV = fn v => Vector.map (v, toVar)
            val liveO = live o toVar
            val deadO = not o liveO
            val deadOV = fn v => Vector.forall (v, deadO)

            val filterV = fn v => Vector.keepAll (v, live)
            val filterOV = fn v => Vector.keepAll (v, liveO)

            val doCodes = 
             fn {possible, exhaustive} => 
                {possible = VS.keepAll (possible, live),
                 exhaustive = exhaustive}

            val doTarget = 
             fn M.T {block, arguments} => M.T {block = block, arguments = filterOV arguments}

            val doSwitch = 
             fn {on, cases, default} => 
                let
                  val help = fn (c, tg) => (c, doTarget tg)
                in {on = on, cases = Vector.map (cases, help), default = Option.map (default, doTarget)}
                end

            val doCut = 
             fn {cont, args, cuts} => {cont = cont, args = filterOV args, cuts = cuts}

            val return =
             fn rv => 
                case getThunk env
                 of SOME fk => M.TReturn (Vector.new1 (fieldDefault fk))
                  | _       => M.TReturn (filterOV rv)

            val interProc = 
             fn {callee, ret, fx} => 
                if (case callee
                     of M.IpEval {typ, eval}  => dead (MU.Eval.thunk eval)
                      | M.IpCall {call, args} => 
                        (case call
                          of M.CCode {ptr, ...}           => dead ptr
                           | M.CClosure {cls, ...}        => dead cls
                           | M.CDirectClosure {code, ...} => dead code))
                then 
                  let
                    val () = Click.dce (getPd env)
                    val tf = 
                        case ret
                         of M.RNormal {rets, block, cuts} => 
                            M.TGoto (M.T {block = block, arguments = Vector.new0 ()})
                          | M.RTail _ => return (Vector.new0 ())
                  in SOME (MS.empty, tf)
                  end
                else 
                  (case callee
                    of M.IpEval {typ, eval}  => 
                       let
                         val eval = 
                             case eval
                              of M.EThunk {thunk, code} => M.EThunk {thunk = thunk, code = doCodes code}
                               | M.EDirectThunk _       => eval
                         val callee = M.IpEval {typ = typ, eval = eval}
                         val ip = M.TInterProc {callee = callee,
                                                ret = ret, fx = fx}
                       in SOME (MS.empty, ip)
                       end
                     | M.IpCall {call, args} => 
                       let
                         val args = filterOV args
                         val call = 
                             case call
                                  of M.CCode {ptr, code}          => M.CCode {ptr = ptr, code = doCodes code}
                                   | M.CClosure {cls, code}       => M.CClosure {cls = cls, code = doCodes code}
                                   | M.CDirectClosure {code, cls} => 
                                     if dead cls then
                                       M.CCode {ptr = code, code = {possible = VS.singleton code, exhaustive = true}}
                                     else
                                       call
                         val callee = M.IpCall {call = call, args = args}
                         val (s, tf) = 
                             case (ret, getThunk env)
                              of (M.RNormal {rets, block, cuts}, _) => 
                                 let
                                       val ret = M.RNormal {rets = filterV rets, block = block, cuts = cuts}
                                 in (MS.empty, M.TInterProc {callee = callee, ret = ret, fx = fx})
                                 end
                               | (M.RTail _, NONE)                  => 
                                 (MS.empty, M.TInterProc {callee = callee, ret = ret, fx = fx})
                               | (M.RTail {exits}, SOME fk)         => 
                                 let
                                   val lbl = Identifier.Manager.labelFresh (getStm state)
                                   val cuts = M.C {exits = exits, targets = LS.empty}
                                   val ret = M.RNormal {rets = Vector.new0 (), block = lbl, cuts = cuts}
                                   val call = M.TInterProc {callee = callee, ret = ret, fx = fx}
                                   val s = MS.transfer (call, lbl, Vector.new0())
                                   val tf = return (Vector.new0())
                                     in (s, tf)
                                 end
                       in SOME (s, tf)
                       end)

            val so = 
                case t
                 of M.TGoto tg      => SOME (MS.empty, M.TGoto (doTarget tg))
                  | M.TCase sw      => SOME (MS.empty, M.TCase (doSwitch sw))
                  | M.TInterProc r  => interProc r
                  | M.TReturn rv    => SOME (MS.empty, return rv)
                  | M.TCut r        => SOME (MS.empty, M.TCut (doCut r))
                  | M.THalt _       => NONE
                  | M.TPSumCase sw  => SOME (MS.empty, M.TPSumCase (doSwitch sw))
          in (env, so)
          end

      val global = 
       fn (state, env, v, g) => 
          let
            val fieldDefault = fn fk => fieldDefault (state, env, fk)
            val dead = fn v => variableIsDead (state, env, v)
            val live = not o dead
            val deadV = fn vs => Vector.forall (vs, dead)
            val liveV = not o deadV
            val keep = fn () => (env, NONE)
            val toVar = 
             fn oper => case oper
                         of M.SVariable v => v
                          | M.SConstant _ => fail ("instr", "Not in named form")
            val toVarV = fn v => Vector.map (v, toVar)
            val liveO = live o toVar
            val filterV = fn v => Vector.keepAll (v, live)
            val filterOV = fn v => Vector.keepAll (v, liveO)
            val kill = fn () => let val () = Click.dce (getPd env) in (env, SOME []) end
            val (env, gso) = 
                if dead v then kill () else
                case g
                 of M.GCode f => 
                    let
                      val M.F {fx, escapes, recursive, cc, args, rtyps, body} = f
                      val cc = 
                          case cc
                           of M.CcCode               => cc
                            | M.CcClosure {cls, fvs} => if dead cls then M.CcCode 
                                                        else M.CcClosure {cls = cls, fvs = filterV fvs}
                            | M.CcThunk {thunk, fvs} => M.CcThunk {thunk = thunk, fvs = filterV fvs}
                      val args = filterV args
                      val code = M.F {fx = fx, escapes = escapes, recursive = recursive, cc = cc, 
                                      args = args, rtyps = rtyps, body = body}
                      val env = 
                          case cc
                           of M.CcThunk {thunk, fvs} => 
                              let
                                val ret =
                                    case MRS.iInfo (getSummary state, MU.Id.G v)
                                     of MRB.IiCode {cargs, args, returns} => Vector.sub (returns, 0)
                                      | _ => fail ("global", "Bad code descriptor")
                                val env = 
                                    if FG.query (getFlowGraph state, ret) then
                                      setThunk (env, NONE)
                                    else
                                      (case MU.FieldKind.fromTyp' (getConfig env, Vector.sub (rtyps, 0))
                                        of SOME fk => setThunk (env, SOME fk)
                                         | NONE    => setThunk (env, SOME M.FkRef))
                              in env
                              end
                            | _ => setThunk (env, NONE)
                    in (env, SOME [(v, M.GCode code)])
                    end
                  | M.GTuple {mdDesc, inits} => 
                    let 
                      val inits = filterOV inits
                    in (env, SOME [(v, M.GTuple {mdDesc = mdDesc, inits = inits})])
                    end
                  | M.GThunkValue {typ, ofVal} => 
                    if liveO ofVal then (env, NONE)
                    else
                      let
                        val oper = fieldDefault typ
                        val g = M.GThunkValue {typ = typ, ofVal = oper}
                      in (env, SOME [(v, g)])
                      end
                  | M.GClosure {code, fvs} => 
                    let
                      val fvs = Vector.keepAll (fvs, fn (fk, s) => liveO s)
                    in (env, SOME [(v, M.GClosure {code = code, fvs = fvs})])
                    end
                  | M.GPSum {tag, typ, ofVal} => 
                    if liveO ofVal then (env, NONE) else
                    let
                      val p = fieldDefault typ
                      val g = M.GPSum {typ = typ, ofVal = p, tag = tag}
                    in (env, SOME [(v, g)])
                    end
                  | M.GPSet s => 
                    if liveO s then (env, NONE) else
                    let
                      val p = fieldDefault M.FkRef
                      val g = M.GPSet p
                      in (env, SOME [(v, g)])
                    end
                  | _ => (env, NONE)
          in (env, gso)
          end

      structure Transform = MilTransformF(struct
                                            type state = state
                                            type env = env
                                            val config = getConfig
                                            val indent = 2
                                            val label = label
                                            val instr = instr
                                            val transfer = transfer
                                            val global = global
                                          end)

      val globals = 
       fn (pd, summary, stm, fg, dead, globals) =>
          let
            val state = S {stm = stm, summary = summary, fg = fg}
            val env = E {pd = pd, dead = dead, thunk = NONE}
            val globals = Transform.globals (state, env, Transform.OAny, globals)
          in globals
          end
    end (* structure Rewrite *)

    val backward1 = 
     fn (pd, summary, p) => 
        let
          val fgB1 = FG.build {pd = pd,
                               forward = false,
                               summary = summary,
                               uDefInit = SOME true,
                               uUseInit = SOME true, 
                               initialize = fn n => false,
                               merge = fn (a, b) => a orelse b,
                               equal = op =
                              }
          val state = SE1.S {summary = summary, flowgraph = fgB1}
          val env = SE1.E {pd = pd, current = NONE}
          val () = Analyze1.analyseProgram (state, env, p)
          val () = FG.propagate fgB1
        in fgB1
        end

    val backward2 = 
     fn (pd, summary, p) => 
        let
          val fgB2 = FG.build {pd = pd,
                               forward = false,
                               summary = summary,
                               uDefInit = SOME true,
                               uUseInit = SOME true, 
                               initialize = fn n => false,
                               merge = fn (a, b) => a orelse b,
                               equal = op =
                              }
          val state = SE2.S {summary = summary, flowgraph = fgB2}
          val env = SE2.E {pd = pd}
          val () = Analyze2.analyseProgram (state, env, p)
          val () = FG.propagate fgB2
        in fgB2
        end

    val forward1 = 
     fn (pd, summary, p, fgB1, fgB2) => 
        let
          val fgF1 = 
              FG.build {pd = pd,
                        forward = true,
                        summary = summary,
                        uDefInit = SOME true,
                        uUseInit = SOME true, 
                        initialize = fn n => FG.query (fgB1, n),
                        merge = fn (a, b) => (a orelse b),
                        equal = op =
                       }
          val state = SE3.S {summary = summary, flowgraph = fgB2, compared = fgB2}
          val env = SE3.E {pd = pd}
          val () = Analyze3.analyseProgram (state, env, p)
          val () = FG.propagate fgF1
        in fgF1
        end

    val deadVars = 
     fn (pd, summary, fg) =>
        let
          val vars = MRS.listVariables summary
          val dead = List.keepAll (vars, fn v => not (FG.query (fg, MRS.variableNode (summary, v))))
        in dead
        end

    val show = 
     fn (pd, summary, fg, p) => 
        if show pd then
          let
            val si = Identifier.SymbolInfo.SiTable (MU.Program.symbolTable p)
            val dead = deadVars (pd, summary, fg)
            val lv = fn v => MilLayout.layoutVariable (PD.getConfig pd, si, v)
            val ls = List.map (dead, lv)
            val l = Layout.mayAlign ls
            val l = Layout.align [Layout.str "Dead variables:", LayoutUtils.indent l]
            val () = LayoutUtils.printLayout l
          in ()
          end
        else
          ()

    val adjustTypes = 
     fn (pd, summary, fg) => 
        let
          val liveN = 
           fn n => FG.query (fg, n)
          val deadN = not o liveN
          val filterV = fn v => Vector.keepAll (v, liveN)
          val update = 
           fn info => 
              case info 
               of MRB.IiCode {cargs, args, returns} => 
                  let
                    val cargs = 
                        case cargs
                         of M.CcCode => cargs
                          | M.CcClosure {cls, fvs} => 
                            if deadN cls then
                              M.CcCode
                            else
                              M.CcClosure {cls = cls, fvs = filterV fvs}
                          | M.CcThunk {thunk, fvs} => 
                            M.CcThunk {thunk = thunk, fvs = filterV fvs}
                    val args = filterV args
                    val returns = 
                        case cargs
                         of M.CcThunk _ => returns
                          | _           => filterV returns
                  in MRB.IiCode {cargs = cargs, args = args, returns = returns}
                  end
                | MRB.IiMetaData {pok, fixed, array} => 
                  let
                    val adjustIndex = 
                     fn i => 
                        let
                          val rec loop = 
                           fn (j, idx) => 
                              if j < i andalso j < Vector.length fixed then 
                                if FG.query (fg, Vector.sub (fixed, j)) then
                                  loop (j + 1, idx + 1)
                                else
                                  loop (j + 1, idx)
                              else 
                                idx
                        in loop (0, 0)
                        end
                    val fixed = filterV fixed
                    val array = Utils.Option.bind (array, fn (i, n) => if deadN n then NONE else SOME (adjustIndex i, n))
                  in MRB.IiMetaData {pok = pok, fixed = fixed, array = array}
                  end
                | MRB.IiTupleDescriptor {fixed, array} => 
                  let
                    val fixed = filterV fixed
                    val array = Utils.Option.bind (array, fn n => if deadN n then NONE else array)
                  in MRB.IiTupleDescriptor {fixed = fixed, array = array}
                  end
                | MRB.IiThunk {typ, fvs} => MRB.IiThunk {typ = typ, fvs = filterV fvs}
                | MRB.IiClosure fvs      => MRB.IiClosure (filterV fvs)
                | MRB.IiPSum n           => info
          val () = MRS.updateIInfo (summary, update)

          val doNode =
           fn (_, n) => 
              let
                val doIt = 
                 fn s => MRN.setShape (n, SOME (MRO.Shape.filter (s, deadN)))
              in 
                if liveN n then
                  Option.foreach (MRN.shape' n, doIt)
                else
                  ()
              end
          val () = ID.foreach (MRS.nodes summary, doNode)
        in ()
        end


    val rewrite = 
     fn (pd, summary, p, fgF1) => 
        let
          val M.P {includes, externs, globals, entry, symbolTable = _} = p
          val dead = deadVars (pd, summary, fgF1)
          val dead = VS.fromList dead
          val stm = I.Manager.fromExistingAll (MU.Program.symbolTable p)
          val globals = Rewrite.globals (pd, summary, stm, fgF1, dead, globals)
          val () = adjustTypes (pd, summary, fgF1)
          val st = I.Manager.finish stm
          val p = M.P {includes = includes, externs = externs, globals = globals, entry = entry, symbolTable = st}
        in p
        end

    val program = 
     fn (pd, summary, p) => 
        let
          val fgB1 = backward1 (pd, summary, p)
          val fgB2 = backward2 (pd, summary, p)
          val fgF1 = forward1 (pd, summary, p, fgB1, fgB2)
          val () = show (pd, summary, fgF1, p)
          val p = rewrite (pd, summary, p, fgF1)
        in p
        end

  end (* structure Dce *)

  val postPhase = 
   fn (pd, p) => 
      let
        val config = PD.getConfig pd
        val () = if statPhases pd then Stats.report (PD.getStats pd) else ()
        val () = if checkPhases pd then MilCheck.program (config, p) else ()
        val () = if showPhases pd then MilLayout.print (config, p) else ()
      in ()
      end

  val doPhase = 
   fn (skip, f, name) =>
   fn (pd, p) => 
      if skip pd then
        let
          val () = Chat.log1 (pd, "Skipping "^name)
        in p
        end
      else
        let
          val pd = PD.push pd
          val () = Chat.log1 (pd, "Doing "^name)
          val s = Time.now ()
          val p = f (pd, p)
          val e = Time.toString (Time.- (Time.now (), s))
          val () = Chat.log1 (pd, "Done with "^name^" in "^e^"s")
          val () = postPhase (pd, p)
        in p
        end

  val preProcess = doPhase (fn _ => false, MilRepPrep.program, "Pre-processing")

  val optimize = fn (pd, summary, p) => 
                    doPhase (Dce.skip, 
                             fn (pd, p) => Dce.program (pd, summary, p),
                             "Optimization") (pd, p)

  val reconstruct = fn (pd, summary, p) => 
                       doPhase (skipReconstruction, 
                                fn (pd, p) => MilRepReconstruct.program (pd, summary, false, p),
                                "Reconstruction") (pd, p)

  val annotate = fn (pd, summary, p) => 
                    doPhase (fn pd => not (annotateProgram pd),
                             fn (pd, p) => MilRepShow.annotate (pd, summary, p),
                             "Annotation") (pd, p)

  val analyze = 
   fn (pd, p) => 
      let
          val () = Chat.log1 (pd, "Doing analysis")
          val summary = MilRepAnalyze.program (pd, p)
          val () = Chat.log1 (pd, "Done with analysis")
          val () = 
              if showAnalysis pd then
                MilRepShow.printAnalysis (pd, summary, p)
              else
                ()
      in summary
      end

  val program = 
   fn (pd, p) =>
      let
        val p = preProcess (pd, p)
        val summary = analyze (pd, p)
        val p = optimize (pd, summary, p)
        val p = reconstruct (pd, summary, p)
        val p = annotate (pd, summary, p)
        val () = PD.report (pd, passname)
      in p
      end

  val description = {name        = passname,
                     description = "Rep dead code optimisation",
                     inIr        = BothMil.irHelpers,
                     outIr       = BothMil.irHelpers,
                     mustBeAfter = [],
                     stats       = stats}

  val associates = {controls  = [],
                    debugs    = debugs,
                    features  = features,
                    subPasses = []}

  val pass =
      Pass.mkOptPass (description, associates, BothMil.mkMilPass (Utils.Function.flipIn program))

end