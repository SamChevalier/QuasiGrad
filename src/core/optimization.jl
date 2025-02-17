# adam solver -- take steps for every element in master_grad (only two states are tracked: m and v)
function adam!(adm::QuasiGrad.Adam, mgd::QuasiGrad.MasterGrad, prm::QuasiGrad.Param, qG::QuasiGrad.QG, stt::QuasiGrad.State, upd::Dict{Symbol, Vector{Vector{Int64}}})
    # => @floop ThreadedEx(basesize = qG.nT ÷ qG.num_threads) for var_key in adm.keys
    for var_key in adm.keys
        # call states and gradients ("getproperty" and "call_adam_states" slower)
        adam_states = getfield(adm, var_key)     
        state       = getfield(stt, var_key)
        grad        = getfield(mgd, var_key)

        # loop over all time
        Threads.@threads for tii in prm.ts.time_keys
            if var_key in keys(upd)
                @inbounds for updates in upd[var_key][tii]
                    adam_states.m[tii][updates] = qG.beta1*adam_states.m[tii][updates] + qG.one_min_beta1*grad[tii][updates]
                    adam_states.v[tii][updates] = qG.beta2*adam_states.v[tii][updates] + qG.one_min_beta2*QuasiGrad.LoopVectorization.pow_fast.(grad[tii][updates], 2)
                    state[tii][updates]         = state[tii][updates]  - qG.alpha_tnow[var_key]*(adam_states.m[tii][updates]/qG.one_min_beta1_decay)/(QuasiGrad.LoopVectorization.sqrt_fast(adam_states.v[tii][updates]/qG.one_min_beta2_decay) + qG.eps)
                end
            else
                if !isempty(adam_states.m[tii])
                    # update adam moments
                        # => clipped_grad, if helpful!  = clamp.(mgd[var_key][tii], -qG.grad_max, qG.grad_max)
                    @turbo adam_states.m[tii] .= qG.beta1.*adam_states.m[tii] .+ qG.one_min_beta1.*grad[tii]
                    @turbo adam_states.v[tii] .= qG.beta2.*adam_states.v[tii] .+ qG.one_min_beta2.*QuasiGrad.LoopVectorization.pow_fast.(grad[tii], 2)
                    @turbo state[tii]         .= state[tii] .- qG.alpha_tnow[var_key].*(adam_states.m[tii]./qG.one_min_beta1_decay)./(QuasiGrad.LoopVectorization.sqrt_fast.(adam_states.v[tii]./qG.one_min_beta2_decay) .+ qG.eps)
                end
            end
        end
    end
end

# adam solver -- take steps for every element in master_grad (only two states are tracked: m and v)
function adam_pf!(adm::QuasiGrad.Adam, mgd::QuasiGrad.MasterGrad, prm::QuasiGrad.Param, qG::QuasiGrad.QG, stt::QuasiGrad.State, upd::Dict{Symbol, Vector{Vector{Int64}}})
    # => @floop ThreadedEx(basesize = qG.nT ÷ qG.num_threads) for var_key in adm.keys
    for var_key in qG.adam_pf_variables
        # call states and gradients ("getproperty" and "call_adam_states" slower)
        adam_states = getfield(adm, var_key)
        state       = getfield(stt, var_key)
        grad        = getfield(mgd, var_key)

        # loop over all time
        Threads.@threads for tii in prm.ts.time_keys
            if var_key in keys(upd)
                @inbounds for updates in upd[var_key][tii]
                    adam_states.m[tii][updates] = qG.beta1*adam_states.m[tii][updates] + qG.one_min_beta1*grad[tii][updates]
                    adam_states.v[tii][updates] = qG.beta2*adam_states.v[tii][updates] + qG.one_min_beta2*QuasiGrad.LoopVectorization.pow_fast.(grad[tii][updates], 2)
                    state[tii][updates]         = state[tii][updates]  - qG.alpha_tnow[var_key]*(adam_states.m[tii][updates]/qG.one_min_beta1_decay)/(QuasiGrad.LoopVectorization.sqrt_fast(adam_states.v[tii][updates]/qG.one_min_beta2_decay) + qG.eps)
                end
            else
                if !isempty(adam_states.m[tii])
                    # update adam moments
                        # => clipped_grad, if helpful!  = clamp.(mgd[var_key][tii], -qG.grad_max, qG.grad_max)
                    @turbo adam_states.m[tii] .= qG.beta1.*adam_states.m[tii] .+ qG.one_min_beta1.*grad[tii]
                    @turbo adam_states.v[tii] .= qG.beta2.*adam_states.v[tii] .+ qG.one_min_beta2.*QuasiGrad.LoopVectorization.pow_fast.(grad[tii], 2)
                    @turbo state[tii]         .= state[tii] .- qG.alpha_tnow[var_key].*(adam_states.m[tii]./qG.one_min_beta1_decay)./(QuasiGrad.LoopVectorization.sqrt_fast.(adam_states.v[tii]./qG.one_min_beta2_decay) .+ qG.eps)
                end
            end
        end
    end
end

# adam solver -- take steps for every element in the master_grad list
function flush_adam!(adm::QuasiGrad.Adam, flw::QuasiGrad.Flow, prm::QuasiGrad.Param, upd::Dict{Symbol, Vector{Vector{Int64}}})
    # loop over the keys in mgd
    for var_key in adm.keys
        adam_states = getfield(adm,var_key)

        # loop over all time
        for tii in prm.ts.time_keys
            # states to update                 
            if var_key in keys(upd)
                # flush the adam moments
                adam_states.m[tii][upd[var_key][tii]] .= 0.0
                adam_states.v[tii][upd[var_key][tii]] .= 0.0
            else
                # flush the adam moments
                adam_states.m[tii] .= 0.0
                adam_states.v[tii] .= 0.0
            end

            # also, flush the ctg gradient buffers!
            flw.dz_dpinj_rolling[tii]        .= 0.0
            flw.dsmax_dqfr_flow_rolling[tii] .= 0.0
            flw.dsmax_dqto_flow_rolling[tii] .= 0.0
        end
    end
end

function run_adam!(adm::QuasiGrad.Adam, cgd::QuasiGrad.ConstantGrad, ctg::QuasiGrad.Contingency, flw::QuasiGrad.Flow, grd::QuasiGrad.Grad, idx::QuasiGrad.Index, mgd::QuasiGrad.MasterGrad, ntk::QuasiGrad.Network, prm::QuasiGrad.Param, qG::QuasiGrad.QG, scr::Dict{Symbol, Float64}, stt::QuasiGrad.State, sys::QuasiGrad.System, upd::Dict{Symbol, Vector{Vector{Int64}}}; clip_pq_based_on_bins::Bool=false)
    # NOTE -- "clip_pq_based_on_bins = true" is only used once all binaries have been fixed!
    #         so, use in on the very last adam iteration after binaries have been set.
    # 
    # here we go!
    @info "Running adam for $(qG.adam_max_time) seconds!"

    # flush adam just once!
    QuasiGrad.flush_adam!(adm, flw, prm, upd)

    # loop and solve adam twice: once for an initialization, and once for a true run
    for lp in 1:2
        if lp == 1
            println("=== running adam 1 (10%) ===")
            qG.skip_ctg_eval = true
            this_runtime     = 0.1*qG.adam_max_time # init
        else
            println("=== running adam 2 (90%) ===")
            qG.skip_ctg_eval = false
            this_runtime     = 0.9*qG.adam_max_time # run
        end

        # re-initialize
        qG.adm_step      = 0
        qG.beta1_decay   = 1.0
        qG.beta2_decay   = 1.0
        qG.one_min_beta1 = 1.0 - qG.beta1 # here for testing, in case beta1 is changed before a run
        qG.one_min_beta2 = 1.0 - qG.beta2 # here for testing, in case beta2 is changed before a run
        run_adam         = true
        
        # flush adam at each restart ?
        # => QuasiGrad.flush_adam!(adm, flw, prm, upd)

        # start the timer!
        adam_start = time()
        # loop over adam steps
        while run_adam

            # increment
            qG.adm_step += 1

            # step decay
            QuasiGrad.adam_step_decay!(qG, time(), adam_start, adam_start+this_runtime)

            # decay beta and pre-compute
            qG.beta1_decay         = qG.beta1_decay*qG.beta1
            qG.beta2_decay         = qG.beta2_decay*qG.beta2
            qG.one_min_beta1_decay = (1.0-qG.beta1_decay)
            qG.one_min_beta2_decay = (1.0-qG.beta2_decay)

            # update weight parameters?
            if qG.apply_grad_weight_homotopy == true
                QuasiGrad.update_penalties!(prm, qG, time(), adam_start, adam_start+this_runtime)
            end

            # compute all states and grads
            QuasiGrad.update_states_and_grads!(cgd, ctg, flw, grd, idx, mgd, ntk, prm, qG, scr, stt, sys, clip_pq_based_on_bins=clip_pq_based_on_bins)

            # take an adam step
            QuasiGrad.adam!(adm, mgd, prm, qG, stt, upd)
            GC.safepoint()
            # experiments!
                # => QuasiGrad.adaGrad!(adm, alpha, beta1, beta2, beta1_decay, beta2_decay, mgd, prm, qG, stt, upd)
                # => QuasiGrad.the_quasiGrad!(adm, mgd, prm, qG, stt, upd)
                # => QuasiGrad.adam_with_ls!(adm, alpha, beta1, beta2, beta1_decay, beta2_decay, mgd, prm, qG, stt, upd, cgd, ctb, ctd, flw, grd, idx, ntk, scr, sys, wct)

            # stop?
            run_adam = QuasiGrad.adam_termination(adam_start, qG, run_adam, this_runtime)
        end
    end

    # one last clip + state computation -- no grad needed!
    qG.eval_grad = false
    QuasiGrad.update_states_and_grads!(cgd, ctg, flw, grd, idx, mgd, ntk, prm, qG, scr, stt, sys)
    qG.eval_grad = true
    qG.skip_ctg_eval = false
end

function run_adam_with_data_collection!(adm::QuasiGrad.Adam, cgd::QuasiGrad.ConstantGrad, ctg::QuasiGrad.Contingency, data_log::Dict{Symbol, Vector{Float64}}, flw::QuasiGrad.Flow, grd::QuasiGrad.Grad, idx::QuasiGrad.Index, mgd::QuasiGrad.MasterGrad, ntk::QuasiGrad.Network, prm::QuasiGrad.Param, qG::QuasiGrad.QG, scr::Dict{Symbol, Float64}, stt::QuasiGrad.State, sys::QuasiGrad.System, upd::Dict{Symbol, Vector{Vector{Int64}}}; clip_pq_based_on_bins::Bool=false)
    # NOTE -- "clip_pq_based_on_bins = true" is only used once all binaries have been fixed!
    #         so, use in on the very last adam iteration after binaries have been set.
    # 
    # here we go!
    @info "Running adam for $(qG.adam_max_time) seconds!"

    # flush adam just once!
    QuasiGrad.flush_adam!(adm, flw, prm, upd)

    # re-initialize
    qG.adm_step      = 0
    qG.beta1_decay   = 1.0
    qG.beta2_decay   = 1.0
    qG.one_min_beta1 = 1.0 - qG.beta1 # here for testing, in case beta1 is changed before a run
    qG.one_min_beta2 = 1.0 - qG.beta2 # here for testing, in case beta2 is changed before a run
    run_adam         = true

    # start the timer!
    adam_start = time()
    # loop over adam steps
    while run_adam

        # increment
        qG.adm_step += 1

        # step decay
        QuasiGrad.adam_step_decay!(qG, time(), adam_start, adam_start+qG.adam_max_time)

        # decay beta and pre-compute
        qG.beta1_decay         = qG.beta1_decay*qG.beta1
        qG.beta2_decay         = qG.beta2_decay*qG.beta2
        qG.one_min_beta1_decay = (1.0-qG.beta1_decay)
        qG.one_min_beta2_decay = (1.0-qG.beta2_decay)

        # update weight parameters?
        if qG.apply_grad_weight_homotopy == true
            QuasiGrad.update_penalties!(prm, qG, time(), adam_start, adam_start+qG.adam_max_time)
        end

        # compute all states and grads
        QuasiGrad.update_states_and_grads!(cgd, ctg, flw, grd, idx, mgd, ntk, prm, qG, scr, stt, sys, clip_pq_based_on_bins=clip_pq_based_on_bins)

        # take an adam step
        QuasiGrad.adam!(adm, mgd, prm, qG, stt, upd)
        GC.safepoint()

        # stop?
        run_adam = QuasiGrad.adam_termination(adam_start, qG, run_adam, qG.adam_max_time)

        # log adam data for plotting
        # => QuasiGrad.log_data(data_log, qG, scr)
    end

end

function run_adam_pf!(adm::QuasiGrad.Adam, cgd::QuasiGrad.ConstantGrad, ctg::QuasiGrad.Contingency, flw::QuasiGrad.Flow, grd::QuasiGrad.Grad, idx::QuasiGrad.Index, mgd::QuasiGrad.MasterGrad, ntk::QuasiGrad.Network, prm::QuasiGrad.Param, qG::QuasiGrad.QG, scr::Dict{Symbol, Float64}, stt::QuasiGrad.State, sys::QuasiGrad.System, upd::Dict{Symbol, Vector{Vector{Int64}}}; first_solve::Bool = false, clip_pq_based_on_bins::Bool=false)
    # here we go! basically, we only compute a small subset of pf-relevant gradients
    @info "Running adam-powerflow for $(qG.adam_max_time) seconds!"

        # re-initialize
        qG.adm_step      = 0
        qG.beta1_decay   = 1.0
        qG.beta2_decay   = 1.0
        qG.one_min_beta1 = 1.0 - qG.beta1 # here for testing, in case beta1 is changed before a run
        qG.one_min_beta2 = 1.0 - qG.beta2 # here for testing, in case beta2 is changed before a run
        run_adam         = true
        
        # flush adam at each restart ?
        QuasiGrad.flush_adam!(adm, flw, prm, upd)

        # start the timer!
        adam_start = time()

        # loop over adam steps
        while run_adam

            # increment
            qG.adm_step += 1

            # step decay
            QuasiGrad.adam_step_decay!(qG, time(), adam_start, adam_start+qG.adam_max_time; adam_pf=true, first_solve=first_solve)

            # decay beta and pre-compute
            qG.beta1_decay         = qG.beta1_decay*qG.beta1
            qG.beta2_decay         = qG.beta2_decay*qG.beta2
            qG.one_min_beta1_decay = (1.0-qG.beta1_decay)
            qG.one_min_beta2_decay = (1.0-qG.beta2_decay)

            # update weight parameters?
            QuasiGrad.update_penalties!(prm, qG, time(), adam_start, adam_start+qG.adam_max_time)

            # compute all states and grads
            QuasiGrad.update_states_and_grads_for_adam_pf!(cgd, grd, idx, mgd, prm, qG, scr, stt, sys; clip_pq_based_on_bins=clip_pq_based_on_bins)

            # take an adam step
            QuasiGrad.adam_pf!(adm, mgd, prm, qG, stt, upd)
            GC.safepoint()

            # stop?
            run_adam = QuasiGrad.adam_termination(adam_start, qG, run_adam, qG.adam_max_time)
        end

    # one last clip + state computation -- no grad needed!
    qG.eval_grad = false
    QuasiGrad.update_states_and_grads!(cgd, ctg, flw, grd, idx, mgd, ntk, prm, qG, scr, stt, sys)
    qG.eval_grad = true
    qG.skip_ctg_eval = false
end

function jack_solves_adam_pf!(adm::QuasiGrad.Adam, cgd::QuasiGrad.ConstantGrad, ctg::QuasiGrad.Contingency, flw::QuasiGrad.Flow, grd::QuasiGrad.Grad, idx::QuasiGrad.Index, mgd::QuasiGrad.MasterGrad, ntk::QuasiGrad.Network, prm::QuasiGrad.Param, qG::QuasiGrad.QG, scr::Dict{Symbol, Float64}, stt::QuasiGrad.State, sys::QuasiGrad.System, upd::Dict{Symbol, Vector{Vector{Int64}}}; first_solve::Bool = false, clip_pq_based_on_bins::Bool=false)
    # here we go! basically, we only compute a small subset of pf-relevant gradients
    @info "Running adam-powerflow for $(qG.adam_max_time) seconds!"

    # in this function, we're going to ball

        # re-initialize
        qG.adm_step      = 0
        qG.beta1_decay   = 1.0
        qG.beta2_decay   = 1.0
        qG.one_min_beta1 = 1.0 - qG.beta1 # here for testing, in case beta1 is changed before a run
        qG.one_min_beta2 = 1.0 - qG.beta2 # here for testing, in case beta2 is changed before a run
        run_adam         = true
        
        # flush adam at each restart ?
        QuasiGrad.flush_adam!(adm, flw, prm, upd)

        # start the timer!
        adam_start = time()

        # loop over adam steps
        while run_adam

            # increment
            qG.adm_step += 1

            # step decay
            QuasiGrad.adam_step_decay!(qG, time(), adam_start, adam_start+qG.adam_max_time; adam_pf=true, first_solve=first_solve)

            # decay beta and pre-compute
            qG.beta1_decay         = qG.beta1_decay*qG.beta1
            qG.beta2_decay         = qG.beta2_decay*qG.beta2
            qG.one_min_beta1_decay = (1.0-qG.beta1_decay)
            qG.one_min_beta2_decay = (1.0-qG.beta2_decay)

            # update weight parameters?
            QuasiGrad.update_penalties!(prm, qG, time(), adam_start, adam_start+qG.adam_max_time)

            # compute all states and grads
            QuasiGrad.update_states_and_grads_for_adam_pf!(cgd, grd, idx, mgd, prm, qG, scr, stt, sys; clip_pq_based_on_bins=clip_pq_based_on_bins)

            # take an adam step
            QuasiGrad.adam_pf!(adm, mgd, prm, qG, stt, upd)
            GC.safepoint()

            # stop?
            run_adam = QuasiGrad.adam_termination(adam_start, qG, run_adam, qG.adam_max_time)
        end

    # one last clip + state computation -- no grad needed!
    qG.eval_grad = false
    QuasiGrad.update_states_and_grads!(cgd, ctg, flw, grd, idx, mgd, ntk, prm, qG, scr, stt, sys)
    qG.eval_grad = true
    qG.skip_ctg_eval = false
end

function update_states_and_grads!(
    cgd::QuasiGrad.ConstantGrad, 
    ctg::QuasiGrad.Contingency,
    flw::QuasiGrad.Flow, 
    grd::QuasiGrad.Grad, 
    idx::QuasiGrad.Index, 
    mgd::QuasiGrad.MasterGrad,
    ntk::QuasiGrad.Network, 
    prm::QuasiGrad.Param, 
    qG::QuasiGrad.QG, 
    scr::Dict{Symbol, Float64}, 
    stt::QuasiGrad.State,
    sys::QuasiGrad.System;
    clip_pq_based_on_bins::Bool=false)

    # safepoint
    GC.safepoint()
    
    # if we are here, we want to make sure we are running su/sd updates
    qG.clip_pq_based_on_bins = false
    qG.run_susd_updates = true

    # flush the gradient -- both master grad and some of the gradient terms
    QuasiGrad.flush_gradients!(grd, mgd, prm, qG, sys)

    # clip all basic states (i.e., the states which are iterated on)
    if clip_pq_based_on_bins == true
        qG.clip_pq_based_on_bins = true
    else
        qG.clip_pq_based_on_bins = false
    end
    QuasiGrad.clip_all!(prm, qG, stt, sys)

    # compute network flows and injections
    QuasiGrad.acline_flows!(grd, idx, prm, qG, stt, sys)
    QuasiGrad.xfm_flows!(grd, idx, prm, qG, stt, sys)
    QuasiGrad.shunts!(grd, idx, prm, qG, stt)

    # device powers
    QuasiGrad.all_device_statuses_and_costs!(grd, prm, qG, stt)
    QuasiGrad.device_startup_states!(grd, idx, mgd, prm, qG, stt, sys)
    QuasiGrad.device_active_powers!(idx, prm, qG, stt, sys)
    QuasiGrad.device_reactive_powers!(idx, prm, qG, stt)
    QuasiGrad.energy_costs!(grd, prm, qG, stt, sys)
    QuasiGrad.energy_penalties!(grd, idx, prm, qG, scr, stt, sys)
    QuasiGrad.penalized_device_constraints!(grd, idx, mgd, prm, qG, scr, stt, sys)
    QuasiGrad.device_reserve_costs!(prm, qG, stt)

    # now, we can compute the power balances
    QuasiGrad.power_balance!(grd, idx, prm, qG, stt, sys)

    # compute reserve margins and penalties (no grads here)
    QuasiGrad.reserve_balance!(idx, prm, qG, stt, sys)

    # score the contingencies and take the gradients
    QuasiGrad.solve_ctgs!(cgd, ctg, flw, grd, idx, mgd, ntk, prm, qG, scr, stt, sys)

    # score the market surplus function
    QuasiGrad.score_zt!(idx, prm, qG, scr, stt) 
    QuasiGrad.score_zbase!(qG, scr)
    QuasiGrad.score_zms!(scr)

    # print the market surplus function value
    QuasiGrad.print_zms(qG, scr)

    # compute the master grad
    QuasiGrad.master_grad!(cgd, grd, idx, mgd, prm, qG, stt, sys)
end

function update_states_and_grads_for_adam_pf!(cgd::QuasiGrad.ConstantGrad, grd::QuasiGrad.Grad, idx::QuasiGrad.Index, mgd::QuasiGrad.MasterGrad, prm::QuasiGrad.Param, qG::QuasiGrad.QG, scr::Dict{Symbol, Float64}, stt::QuasiGrad.State, sys::QuasiGrad.System; clip_pq_based_on_bins::Bool=false)
    # update the non-device states which affect power balance
    #
    # if we are here, we want to make sure we are NOT running su/sd updates
    qG.run_susd_updates = false

    # flush the gradient -- both master grad and some of the gradient terms
    QuasiGrad.flush_gradients!(grd, mgd, prm, qG, sys)

    # clip all basic states (i.e., the states which are iterated on)
    if clip_pq_based_on_bins == true
        qG.clip_pq_based_on_bins = true
    else
        qG.clip_pq_based_on_bins = false
    end
    QuasiGrad.clip_for_adam_pf!(prm, qG, stt, sys) # no need to touch bins, reserves

    # compute network flows and injections
    QuasiGrad.acline_flows!(grd, idx, prm, qG, stt, sys)
    QuasiGrad.xfm_flows!(grd, idx, prm, qG, stt, sys)
    QuasiGrad.shunts!(grd, idx, prm, qG, stt)

    # device powers
    QuasiGrad.device_active_powers!(idx, prm, qG, stt, sys)
    QuasiGrad.device_reactive_powers!(idx, prm, qG, stt)
    # => QuasiGrad.energy_costs!(grd, prm, qG, stt, sys)

    # now, we can compute the power balances
    QuasiGrad.power_balance!(grd, idx, prm, qG, stt, sys)

    # score the market surplus function
    QuasiGrad.score_zt!(idx, prm, qG, scr, stt) 

    # print the market surplus function value
    QuasiGrad.print_zms_adam_pf(qG, scr)

    # compute the master grad
    QuasiGrad.master_grad_adam_pf!(cgd, grd, idx, mgd, prm, qG, stt, sys)
end

function batch_fix!(pct_round::Float64, prm::QuasiGrad.Param, stt::QuasiGrad.State, sys::QuasiGrad.System, upd::Dict{Symbol, Vector{Vector{Int64}}})
    # loop and concatenate
    bin_vec_del = Vector{Float64}(undef,(sys.nT*sys.ndev))

    for tii in prm.ts.time_keys
        bin_inds               = (1:sys.ndev) .+ (tii-1)*sys.ndev
        bin_vec_del[bin_inds] .= abs.(stt.u_on_dev[tii] .- stt.u_on_dev_GRB[tii])
    end

    # sort and find the binaries that are closest to Gurobi's solution
    # 
    # which ones do we fix?
    num_bin_fix = Int64(round(sys.nT*sys.ndev*pct_round/100.0))
    bins_to_fix = sortperm(bin_vec_del)[1:num_bin_fix]
    # FYI!!! => most_sim_to_least_sim = sortperm(abs.(bin_vec_del))

    # now, we loop over time and check for each binary in "bins_to_fix"
    for tii in prm.ts.time_keys
        bin_inds          = (1:sys.ndev) .+ (tii-1)*sys.ndev
        local_bins_to_fix = findall(bin_inds .∈ [bins_to_fix])

        # now, we have that:
            # i)  upd[:u_on_dev][tii] are binaries that should move, and
            # ii) local_bins_to_fix are binaries that should not move
        # there will be overlap, but there local_bins_to_fix might not contain
        # everything that upd contains -- thus, we want their union!
        upd[:u_on_dev][tii] = setdiff(upd[:u_on_dev][tii], local_bins_to_fix)

        # now, for "bin_inds" which are to be fixed, delete them
        # no!! => deleteat!(upd[:u_on_dev][tii],local_bins_to_fix)
    end
end

# test solution soln_status
function solution_status(model::QuasiGrad.Model)
    # to get all potential statuses, call: typeof(termination_status(model))
    # 
    #   OPTIMIZE_NOT_CALLED = 0
    #   OPTIMAL = 1
    #   INFEASIBLE = 2
    #   DUAL_INFEASIBLE = 3
    #   LOCALLY_SOLVED = 4
    #   LOCALLY_INFEASIBLE = 5
    #   INFEASIBLE_OR_UNBOUNDED = 6
    #   ALMOST_OPTIMAL = 7
    #   ALMOST_INFEASIBLE = 8
    #   ALMOST_DUAL_INFEASIBLE = 9
    #   ALMOST_LOCALLY_SOLVED = 10
    #   ITERATION_LIMIT = 11
    #   TIME_LIMIT = 12
    #   NODE_LIMIT = 13
    #   SOLUTION_LIMIT = 14
    #   MEMORY_LIMIT = 15
    #   OBJECTIVE_LIMIT = 16
    #   NORM_LIMIT = 17
    #   OTHER_LIMIT = 18
    #   SLOW_PROGRESS = 19
    #   NUMERICAL_ERROR = 20
    #   INVALID_MODEL = 21
    #   INVALID_OPTION = 22
    #   INTERRUPTED = 23
    #   OTHER_ERROR = 24
    # => println(termination_status(model))
    # => println(Int(termination_status(model)))
    soln_status = Int(termination_status(model))
    if soln_status in [1, 4, 7] # optimal, locally solved, or almost optimal
        soln_valid = true
    else
        if Int(primal_status(model)) == 1
            @warn "Projection solution not optimal, but it is feasible."
            soln_valid = true
        else
            soln_valid = false
            println(termination_status(model))
            println(Int(termination_status(model)))
        end
    end

    # output
    return soln_valid
end

function adam_termination(adam_start::Float64, qG::QuasiGrad.QG, run_adam::Bool, this_runtime::Float64)
    # stopping criteria
    if qG.adam_stopper == "time"
        if time() - adam_start >= this_runtime # => qG.adam_max_time
            run_adam = false
        end
    elseif qG.adam_stopper == "iterations"
        if qG.adm_step >= qG.adam_max_its
            run_adam = false
        end
    else
        # uh-oh -- no stopper!
    end

    # output
    return run_adam
end

# call states
function call_adam_states(adm::QuasiGrad.Adam, mgd::QuasiGrad.MasterGrad, stt::QuasiGrad.State, var_key::Symbol)
    # we need this function because calling struct field programatically
    # isn't straightforward, and getfield() tends to allocate
    if var_key == :vm
        adam_states = adm.vm   
        state       = stt.vm
        grad        = mgd.vm
    elseif var_key == :va
        adam_states = adm.va
        state       = stt.va
        grad        = mgd.va
    elseif var_key == :tau
        adam_states = adm.tau
        state       = stt.tau
        grad        = mgd.tau
    elseif var_key == :phi
        adam_states = adm.phi
        state       = stt.phi
        grad        = mgd.phi
    elseif var_key == :dc_pfr
        adam_states = adm.dc_pfr
        state       = stt.dc_pfr
        grad        = mgd.dc_pfr
    elseif var_key == :dc_qfr
        adam_states = adm.dc_qfr
        state       = stt.dc_qfr
        grad        = mgd.dc_qfr
    elseif var_key == :dc_qto
        adam_states = adm.dc_qto
        state       = stt.dc_qto
        grad        = mgd.dc_qto
    elseif var_key == :u_on_acline
        adam_states = adm.u_on_acline
        state       = stt.u_on_acline
        grad        = mgd.u_on_acline
    elseif var_key == :u_on_xfm
        adam_states = adm.u_on_xfm
        state       = stt.u_on_xfm
        grad        = mgd.u_on_xfm
    elseif var_key == :u_step_shunt
        adam_states = adm.u_step_shunt
        state       = stt.u_step_shunt
        grad        = mgd.u_step_shunt
    elseif var_key == :u_on_dev
        adam_states = adm.u_on_dev
        state       = stt.u_on_dev
        grad        = mgd.u_on_dev
    elseif var_key == :p_on
        adam_states = adm.p_on
        state       = stt.p_on
        grad        = mgd.p_on
    elseif var_key == :dev_q
        adam_states = adm.dev_q
        state       = stt.dev_q
        grad        = mgd.dev_q
    elseif var_key == :p_rgu
        adam_states = adm.p_rgu
        state       = stt.p_rgu
        grad        = mgd.p_rgu
    elseif var_key == :p_rgd
        adam_states = adm.p_rgd
        state       = stt.p_rgd
        grad        = mgd.p_rgd
    elseif var_key == :p_scr
        adam_states = adm.p_scr
        state       = stt.p_scr
        grad        = mgd.p_scr
    elseif var_key == :p_nsc
        adam_states = adm.p_nsc
        state       = stt.p_nsc
        grad        = mgd.p_nsc
    elseif var_key == :p_rru_on
        adam_states = adm.p_rru_on
        state       = stt.p_rru_on
        grad        = mgd.p_rru_on
    elseif var_key == :p_rrd_on
        adam_states = adm.p_rrd_on
        state       = stt.p_rrd_on
        grad        = mgd.p_rrd_on
    elseif var_key == :p_rru_off
        adam_states = adm.p_rru_off
        state       = stt.p_rru_off
        grad        = mgd.p_rru_off
    elseif var_key == :p_rrd_off
        adam_states = adm.p_rrd_off
        state       = stt.p_rrd_off
        grad        = mgd.p_rrd_off
    elseif var_key == :q_qru
        adam_states = adm.q_qru
        state       = stt.q_qru
        grad        = mgd.q_qru
    elseif var_key == :q_qrd
        adam_states = adm.q_qrd
        state       = stt.q_qrd
        grad        = mgd.q_qrd
    else
        println("Field not recognized.")
    end

    # output
    return adam_states, grad, state
end

function log_data(data_log::Dict{Symbol, Vector{Float64}}, qG::QuasiGrad.QG, scr::Dict{Symbol, Float64})
    data_log[:zms][qG.adm_step]  = scale_z(scr[:zms])
    data_log[:pzms][qG.adm_step] = scale_z(scr[:zms_penalized])      
    data_log[:zhat][qG.adm_step] = scale_z(scr[:zt_penalty] - qG.constraint_grad_weight*scr[:zhat_mxst])
    data_log[:ctg][qG.adm_step]  = scale_z(scr[:zctg_min] + scr[:zctg_avg])
    data_log[:emnx][qG.adm_step] = scale_z(scr[:emnx])
    data_log[:zp][qG.adm_step]   = scale_z(scr[:zp])
    data_log[:zq][qG.adm_step]   = scale_z(scr[:zq])
    data_log[:acl][qG.adm_step]  = scale_z(scr[:acl])
    data_log[:xfm][qG.adm_step]  = scale_z(scr[:xfm])
    data_log[:zoud][qG.adm_step] = scale_z(scr[:zoud])
    data_log[:zone][qG.adm_step] = scale_z(scr[:zone])
    data_log[:rsv][qG.adm_step]  = scale_z(scr[:rsv])
    data_log[:enpr][qG.adm_step] = scale_z(scr[:enpr])
    data_log[:encs][qG.adm_step] = scale_z(scr[:encs])
    data_log[:zsus][qG.adm_step] = scale_z(scr[:zsus])
end

# function to rescale scores for plotting :)
function scale_z(z::Float64)
    sgn  = sign(z .+ 1e-6)
    absz = abs(z)
    if absz < 1000.0 # clip
        absz = 1000.0
    end
    if sgn < 0
        # shift up two
        zs = sgn*log10(absz) + 3.0
    else
        # shift down two
        zs = sgn*log10(absz) - 3.0
        # +10^5 => 2
        # +10^4 => 1
        # -10^1/2/3 = +10^1/2/3 => 0
        # -10^4 => -1
        # -10^5 => -2
    end

    # output
    return zs
end