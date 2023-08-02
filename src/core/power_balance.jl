function power_balance!(grd::quasiGrad.Grad, idx::quasiGrad.Index, msc::quasiGrad.Msc, prm::quasiGrad.Param, qG::quasiGrad.QG, stt::quasiGrad.State, sys::quasiGrad.System)
    # call penalty cost
    cp = prm.vio.p_bus * qG.scale_c_pbus_testing
    cq = prm.vio.q_bus * qG.scale_c_qbus_testing

    # loop over each time period and compute the power balance
    @batch per=thread for tii in prm.ts.time_keys
    # => @floop ThreadedEx(basesize = qG.nT ÷ qG.num_threads) for tii in prm.ts.time_keys
        # duration
        dt = prm.ts.duration[tii]

        # loop over each bus and aggregate powers
        for bus in 1:sys.nb
            quasiGrad.pq_sums!(bus, idx, msc, stt, tii)
        end

        # actual mismatch penalty
        stt.zp[tii] .= abs.(msc.pb_slack[tii]).*(cp*dt)
        stt.zq[tii] .= abs.(msc.qb_slack[tii]).*(cq*dt)

        # evaluate the grad?
        if qG.eval_grad
            if qG.pqbal_grad_type == "standard"
                grd.zp.pb_slack[tii] .= (cp*dt).*sign.(msc.pb_slack[tii])
                grd.zq.qb_slack[tii] .= (cq*dt).*sign.(msc.qb_slack[tii])
            elseif qG.pqbal_grad_type == "soft_abs"
                grd.zp.pb_slack[tii] .= (qG.pqbal_grad_weight_p*dt).*msc.pb_slack[tii]./(sqrt.(msc.pb_slack[tii].^2 .+ qG.pqbal_grad_eps2))
                grd.zq.qb_slack[tii] .= (qG.pqbal_grad_weight_q*dt).*msc.qb_slack[tii]./(sqrt.(msc.qb_slack[tii].^2 .+ qG.pqbal_grad_eps2))
            elseif qG.pqbal_grad_type == "quadratic_for_lbfgs"
                grd.zp.pb_slack[tii] .= (cp*dt).*msc.pb_slack[tii]
                grd.zq.qb_slack[tii] .= (cq*dt).*msc.qb_slack[tii]
            else
                println("not recognized!")
            end
        end
    end

    # sleep tasks
    quasiGrad.Polyester.ThreadingUtilities.sleep_all_tasks()
end

# fast sum
function pq_sums!(bus::Int64, idx::quasiGrad.Index, msc::quasiGrad.Msc, stt::quasiGrad.State, tii::Int8)
    # loop over devices
    #
    msc.pb_slack[tii][bus] = 0.0
    msc.qb_slack[tii][bus] = 0.0

    # consumers -- positive
    for cs in idx.cs[bus]
        msc.pb_slack[tii][bus] += stt.dev_p[tii][cs]
        msc.qb_slack[tii][bus] += stt.dev_q[tii][cs]
    end

    # shunts -- positive
    for sh in idx.sh[bus]
        msc.pb_slack[tii][bus] += stt.sh_p[tii][sh]
        msc.qb_slack[tii][bus] += stt.sh_q[tii][sh]
    end

    # acline -- positive
    for acl in idx.bus_is_acline_frs[bus]
        msc.pb_slack[tii][bus] += stt.acline_pfr[tii][acl]
        msc.qb_slack[tii][bus] += stt.acline_qfr[tii][acl]
    end
    for acl in idx.bus_is_acline_tos[bus]
        msc.pb_slack[tii][bus] += stt.acline_pto[tii][acl]
        msc.qb_slack[tii][bus] += stt.acline_qto[tii][acl]
    end

    # xfm -- positive
    for xfm in idx.bus_is_xfm_frs[bus]
        msc.pb_slack[tii][bus] += stt.xfm_pfr[tii][xfm]
        msc.qb_slack[tii][bus] += stt.xfm_qfr[tii][xfm]
    end
    for xfm in idx.bus_is_xfm_tos[bus]
        msc.pb_slack[tii][bus] += stt.xfm_pto[tii][xfm]
        msc.qb_slack[tii][bus] += stt.xfm_qto[tii][xfm]
    end

    # dcline -- positive
    for dc in idx.bus_is_dc_frs[bus]
        msc.pb_slack[tii][bus] += stt.dc_pfr[tii][dc]
        msc.qb_slack[tii][bus] += stt.dc_qfr[tii][dc]
    end
    for dc in idx.bus_is_dc_tos[bus] 
        msc.pb_slack[tii][bus] += stt.dc_pto[tii][dc]
        msc.qb_slack[tii][bus] += stt.dc_qto[tii][dc]
    end

    # producer -- NEGATIVE
    for pr in idx.pr[bus]
        msc.pb_slack[tii][bus] -= stt.dev_p[tii][pr]
        msc.qb_slack[tii][bus] -= stt.dev_q[tii][pr]
    end
end