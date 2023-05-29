using JuMP
using Gurobi

ED = deepcopy(GRB)

# build and empty the model!
model = Model(quasiGrad.Gurobi.Optimizer)
empty!(model)

# quiet down!!!
quasiGrad.set_optimizer_attribute(model, "OutputFlag", 1)

# set model properties
quasiGrad.set_optimizer_attribute(model, "FeasibilityTol", qG.FeasibilityTol)
quasiGrad.set_optimizer_attribute(model, "MIPGap",         qG.mip_gap)
quasiGrad.set_optimizer_attribute(model, "TimeLimit",      qG.time_lim)

# define local time keys
tkeys = prm.ts.time_keys

# define the minimum set of variables we will need to solve the constraints
u_on_dev  = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "u_on_dev_t$(ii)",  [dev = 1:sys.ndev], start=stt[:u_on_dev][tkeys[ii]][dev],  lower_bound = 0.0, upper_bound = 1.0) for ii in 1:(sys.nT))
p_on      = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_on_t$(ii)",      [dev = 1:sys.ndev], start=stt[:p_on][tkeys[ii]][dev])                                            for ii in 1:(sys.nT))
dev_q     = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "dev_q_t$(ii)",     [dev = 1:sys.ndev], start=stt[:dev_q][tkeys[ii]][dev],     lower_bound = 0.0)                    for ii in 1:(sys.nT))
p_rgu     = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_rgu_t$(ii)",     [dev = 1:sys.ndev], start=stt[:p_rgu][tkeys[ii]][dev],     lower_bound = 0.0)                    for ii in 1:(sys.nT))
p_rgd     = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_rgd_t$(ii)",     [dev = 1:sys.ndev], start=stt[:p_rgd][tkeys[ii]][dev],     lower_bound = 0.0)                    for ii in 1:(sys.nT))
p_scr     = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_scr_t$(ii)",     [dev = 1:sys.ndev], start=stt[:p_scr][tkeys[ii]][dev],     lower_bound = 0.0)                    for ii in 1:(sys.nT))
p_nsc     = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_nsc_t$(ii)",     [dev = 1:sys.ndev], start=stt[:p_nsc][tkeys[ii]][dev],     lower_bound = 0.0)                    for ii in 1:(sys.nT))
p_rru_on  = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_rru_on_t$(ii)",  [dev = 1:sys.ndev], start=stt[:p_rru_on][tkeys[ii]][dev],  lower_bound = 0.0)                    for ii in 1:(sys.nT))
p_rru_off = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_rru_off_t$(ii)", [dev = 1:sys.ndev], start=stt[:p_rru_off][tkeys[ii]][dev], lower_bound = 0.0)                    for ii in 1:(sys.nT))
p_rrd_on  = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_rrd_on_t$(ii)",  [dev = 1:sys.ndev], start=stt[:p_rrd_on][tkeys[ii]][dev],  lower_bound = 0.0)                    for ii in 1:(sys.nT))
p_rrd_off = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_rrd_off_t$(ii)", [dev = 1:sys.ndev], start=stt[:p_rrd_off][tkeys[ii]][dev], lower_bound = 0.0)                    for ii in 1:(sys.nT))
q_qru     = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "q_qru_t$(ii)",     [dev = 1:sys.ndev], start=stt[:q_qru][tkeys[ii]][dev],     lower_bound = 0.0)                    for ii in 1:(sys.nT))
q_qrd     = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "q_qrd_t$(ii)",     [dev = 1:sys.ndev], start=stt[:q_qrd][tkeys[ii]][dev],     lower_bound = 0.0)                    for ii in 1:(sys.nT))

# add a few more (implicit) variables which are necessary for solving this system
u_su_dev = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "u_su_dev_t$(ii)", [dev = 1:sys.ndev], start=stt[:u_su_dev][tkeys[ii]][dev], lower_bound = 0.0, upper_bound = 1.0) for ii in 1:(sys.nT))
u_sd_dev = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "u_sd_dev_t$(ii)", [dev = 1:sys.ndev], start=stt[:u_sd_dev][tkeys[ii]][dev], lower_bound = 0.0, upper_bound = 1.0) for ii in 1:(sys.nT))

# we have the affine "AffExpr" expressions (whose values are specified)
dev_p   = Dict{Symbol, Vector{AffExpr}}(tkeys[ii] => Vector{AffExpr}(undef, sys.ndev) for ii in 1:(sys.nT))
p_su    = Dict{Symbol, Vector{AffExpr}}(tkeys[ii] => Vector{AffExpr}(undef, sys.ndev) for ii in 1:(sys.nT))
p_sd    = Dict{Symbol, Vector{AffExpr}}(tkeys[ii] => Vector{AffExpr}(undef, sys.ndev) for ii in 1:(sys.nT))
zen_dev = Dict{Symbol, Vector{AffExpr}}(tkeys[ii] => Vector{AffExpr}(undef, sys.ndev) for ii in 1:(sys.nT))

# now, we need to loop and set the affine expressions to 0
#   -> see: https://jump.dev/JuMP.jl/stable/manual/expressions/
for tii in prm.ts.time_keys
    for dev in 1:sys.ndev
        dev_p[tii][dev]   = AffExpr(0.0)
        p_su[tii][dev]    = AffExpr(0.0)
        p_sd[tii][dev]    = AffExpr(0.0)
        zen_dev[tii][dev] = AffExpr(0.0)
    end
end

# add scoring variables and affine terms
p_rgu_zonal_REQ     = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_rgu_zonal_REQ_t$(ii)",     [1:sys.nzP], lower_bound = 0.0) for ii in 1:(sys.nT))
p_rgd_zonal_REQ     = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_rgd_zonal_REQ_t$(ii)",     [1:sys.nzP], lower_bound = 0.0) for ii in 1:(sys.nT))
p_scr_zonal_REQ     = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_scr_zonal_REQ_t$(ii)",     [1:sys.nzP], lower_bound = 0.0) for ii in 1:(sys.nT))
p_nsc_zonal_REQ     = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_nsc_zonal_REQ_t$(ii)",     [1:sys.nzP], lower_bound = 0.0) for ii in 1:(sys.nT))
p_rgu_zonal_penalty = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_rgu_zonal_penalty_t$(ii)", [1:sys.nzP], lower_bound = 0.0) for ii in 1:(sys.nT))
p_rgd_zonal_penalty = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_rgd_zonal_penalty_t$(ii)", [1:sys.nzP], lower_bound = 0.0) for ii in 1:(sys.nT))
p_scr_zonal_penalty = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_scr_zonal_penalty_t$(ii)", [1:sys.nzP], lower_bound = 0.0) for ii in 1:(sys.nT))
p_nsc_zonal_penalty = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_nsc_zonal_penalty_t$(ii)", [1:sys.nzP], lower_bound = 0.0) for ii in 1:(sys.nT))
p_rru_zonal_penalty = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_rru_zonal_penalty_t$(ii)", [1:sys.nzP], lower_bound = 0.0) for ii in 1:(sys.nT))
p_rrd_zonal_penalty = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "p_rrd_zonal_penalty_t$(ii)", [1:sys.nzP], lower_bound = 0.0) for ii in 1:(sys.nT))
q_qru_zonal_penalty = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "q_qru_zonal_penalty_t$(ii)", [1:sys.nzQ], lower_bound = 0.0) for ii in 1:(sys.nT))
q_qrd_zonal_penalty = Dict{Symbol, Vector{quasiGrad.VariableRef}}(tkeys[ii] => @variable(model, base_name = "q_qrd_zonal_penalty_t$(ii)", [1:sys.nzQ], lower_bound = 0.0) for ii in 1:(sys.nT))

# affine aggregation terms
zt      = AffExpr(0.0)
z_enmax = AffExpr(0.0)
z_enmin = AffExpr(0.0)

# loop over all devices
for dev in 1:sys.ndev

    # == define active power constraints ==
    for (t_ind, tii) in enumerate(prm.ts.time_keys)
        # first, get the startup power
        T_supc     = idx.Ts_supc[dev][t_ind]     # T_set, p_supc_set = get_supc(tii, dev, prm)
        p_supc_set = idx.ps_supc_set[dev][t_ind] # T_set, p_supc_set = get_supc(tii, dev, prm)
        add_to_expression!(p_su[tii][dev], sum(p_supc_set[ii]*u_su_dev[tii_inst][dev] for (ii,tii_inst) in enumerate(T_supc); init=0.0))

        # second, get the shutdown power
        T_sdpc     = idx.Ts_sdpc[dev][t_ind]     # T_set, p_sdpc_set = get_sdpc(tii, dev, prm)
        p_sdpc_set = idx.ps_sdpc_set[dev][t_ind] # T_set, p_sdpc_set = get_sdpc(tii, dev, prm)
        add_to_expression!(p_sd[tii][dev], sum(p_sdpc_set[ii]*u_sd_dev[tii_inst][dev] for (ii,tii_inst) in enumerate(T_sdpc); init=0.0))

        # finally, get the total power balance
        dev_p[tii][dev] = p_on[tii][dev] + p_su[tii][dev] + p_sd[tii][dev]
    end

    # == define reactive power constraints ==
    for (t_ind, tii) in enumerate(prm.ts.time_keys)
        # only a subset of devices will have a reactive power equality constraint
        if dev in idx.J_pqe

            # the following (pr vs cs) are equivalent
            if dev in idx.pr_devs
                # producer?
                T_supc = idx.Ts_supc[dev][t_ind] # T_supc, ~ = get_supc(tii, dev, prm)
                T_sdpc = idx.Ts_sdpc[dev][t_ind] # T_sdpc, ~ = get_sdpc(tii, dev, prm)
                u_sum  = u_on_dev[tii][dev] + sum(u_su_dev[tii_inst][dev] for tii_inst in T_supc; init=0.0) + sum(u_sd_dev[tii_inst][dev] for tii_inst in T_sdpc; init=0.0)
                
                # compute q -- this might be the only equality constraint (and below)
                @constraint(model, dev_q[tii][dev] == prm.dev.q_0[dev]*u_sum + prm.dev.beta[dev]*dev_p[tii][dev])
            else
                # the device must be a consumer :)
                T_supc = idx.Ts_supc[dev][t_ind] # T_supc, ~ = get_supc(tii, dev, prm) T_supc     = idx.Ts_supc[dev][t_ind] #T_supc, ~ = get_supc(tii, dev, prm)
                T_sdpc = idx.Ts_sdpc[dev][t_ind] # T_sdpc, ~ = get_sdpc(tii, dev, prm) T_sdpc, ~ = get_sdpc(tii, dev, prm)
                u_sum  = u_on_dev[tii][dev] + sum(u_su_dev[tii_inst][dev] for tii_inst in T_supc; init=0.0) + sum(u_sd_dev[tii_inst][dev] for tii_inst in T_sdpc; init=0.0)

                # compute q -- this might be the only equality constraint (and above)
                @constraint(model, dev_q[tii][dev] == prm.dev.q_0[dev]*u_sum + prm.dev.beta[dev]*dev_p[tii][dev])
            end
        end
    end

    # loop over each time period and define the hard constraints
    for (t_ind, tii) in enumerate(prm.ts.time_keys)
        # duration
        dt = prm.ts.duration[tii]

        # 1. Minimum downtime: zhat_mndn
        T_mndn = idx.Ts_mndn[dev][t_ind] # t_set = get_tmindn(tii, dev, prm)
        @constraint(model, u_su_dev[tii][dev] + sum(u_sd_dev[tii_inst][dev] for tii_inst in T_mndn; init=0.0) - 1.0 <= 0)

        # 2. Minimum uptime: zhat_mnup
        T_mnup = idx.Ts_mnup[dev][t_ind] # t_set = get_tminup(tii, dev, prm)
        @constraint(model, u_sd_dev[tii][dev] + sum(u_su_dev[tii_inst][dev] for tii_inst in T_mnup; init=0.0) - 1.0 <= 0)

        # define the previous power value (used by both up and down ramping!)
        if tii == :t1
            # note: p0 = prm.dev.init_p[dev]
            dev_p_previous = prm.dev.init_p[dev]
        else
            # grab previous time
            tii_m1 = prm.ts.time_keys[t_ind-1]
            dev_p_previous = dev_p[tii_m1][dev]
        end

        # 3. Ramping limits (up): zhat_rup
        @constraint(model, dev_p[tii][dev] - dev_p_previous
                - dt*(prm.dev.p_ramp_up_ub[dev]     *(u_on_dev[tii][dev] - u_su_dev[tii][dev])
                +     prm.dev.p_startup_ramp_ub[dev]*(u_su_dev[tii][dev] + 1.0 - u_on_dev[tii][dev])) <= 0)

        # 4. Ramping limits (down): zhat_rd
        @constraint(model,  dev_p_previous - dev_p[tii][dev]
                - dt*(prm.dev.p_ramp_down_ub[dev]*u_on_dev[tii][dev]
                +     prm.dev.p_shutdown_ramp_ub[dev]*(1.0-u_on_dev[tii][dev])) <= 0)

        # 5. Regulation up: zhat_rgu
        @constraint(model, p_rgu[tii][dev] - prm.dev.p_reg_res_up_ub[dev]*u_on_dev[tii][dev] <= 0)

        # 6. Regulation down: zhat_rgd
        @constraint(model, p_rgd[tii][dev] - prm.dev.p_reg_res_down_ub[dev]*u_on_dev[tii][dev] <= 0)

        # 7. Synchronized reserve: zhat_scr
        @constraint(model, p_rgu[tii][dev] + p_scr[tii][dev] - prm.dev.p_syn_res_ub[dev]*u_on_dev[tii][dev] <= 0)

        # 8. Synchronized reserve: zhat_nsc
        @constraint(model, p_nsc[tii][dev] - prm.dev.p_nsyn_res_ub[dev]*(1.0 - u_on_dev[tii][dev]) <= 0)

        # 9. Ramping reserve up (on): zhat_rruon
        @constraint(model, p_rgu[tii][dev] + p_scr[tii][dev] + p_rru_on[tii][dev] - prm.dev.p_ramp_res_up_online_ub[dev]*u_on_dev[tii][dev] <= 0)

        # 10. Ramping reserve up (off): zhat_rruoff
        @constraint(model, p_nsc[tii][dev] + p_rru_off[tii][dev] - prm.dev.p_ramp_res_up_offline_ub[dev]*(1.0-u_on_dev[tii][dev]) <= 0)
        
        # 11. Ramping reserve down (on): zhat_rrdon
        @constraint(model, p_rgd[tii][dev] + p_rrd_on[tii][dev] - prm.dev.p_ramp_res_down_online_ub[dev]*u_on_dev[tii][dev] <= 0)

        # 12. Ramping reserve down (off): zhat_rrdoff
        @constraint(model, p_rrd_off[tii][dev] - prm.dev.p_ramp_res_down_offline_ub[dev]*(1-u_on_dev[tii][dev]) <= 0)
        
        # Now, we must separate: producers vs consumers
        if dev in idx.pr_devs
            # 13p. Maximum reserve limits (producers): zhat_pmax
            @constraint(model, p_on[tii][dev] + p_rgu[tii][dev] + p_scr[tii][dev] + p_rru_on[tii][dev] - prm.dev.p_ub[dev][t_ind]*u_on_dev[tii][dev] <= 0)
        
            # 14p. Minimum reserve limits (producers): zhat_pmin
            @constraint(model, prm.dev.p_lb[dev][t_ind]*u_on_dev[tii][dev] + p_rrd_on[tii][dev] + p_rgd[tii][dev] - p_on[tii][dev] <= 0)
            
            # 15p. Off reserve limits (producers): zhat_pmaxoff
            @constraint(model, p_su[tii][dev] + p_sd[tii][dev] + p_nsc[tii][dev] + p_rru_off[tii][dev] - prm.dev.p_ub[dev][t_ind]*(1.0 - u_on_dev[tii][dev]) <= 0)

            # get common "u_sum" terms that will be used in the subsequent four equations 
            T_supc = idx.Ts_supc[dev][t_ind] # T_supc, ~ = get_supc(tii, dev, prm) T_supc     = idx.Ts_supc[dev][t_ind] # T_supc, ~ = get_supc(tii, dev, prm)
            T_sdpc = idx.Ts_sdpc[dev][t_ind] # T_sdpc, ~ = get_sdpc(tii, dev, prm) T_sdpc, ~ = get_sdpc(tii, dev, prm)
            u_sum     = u_on_dev[tii][dev] + sum(u_su_dev[tii_inst][dev] for tii_inst in T_supc; init=0.0) + sum(u_sd_dev[tii_inst][dev] for tii_inst in T_sdpc; init=0.0)

            # 16p. Maximum reactive power reserves (producers): zhat_qmax
            @constraint(model, dev_q[tii][dev] + q_qru[tii][dev] - prm.dev.q_ub[dev][t_ind]*u_sum <= 0)

            # 17p. Minimum reactive power reserves (producers): zhat_qmin
            @constraint(model, q_qrd[tii][dev] + prm.dev.q_lb[dev][t_ind]*u_sum - dev_q[tii][dev] <= 0)

            # 18p. Linked maximum reactive power reserves (producers): zhat_qmax_beta
            if dev in idx.J_pqmax
                @constraint(model, dev_q[tii][dev] + q_qru[tii][dev] - prm.dev.q_0_ub[dev]*u_sum
                - prm.dev.beta_ub[dev]*dev_p[tii][dev] <= 0)
            end 
            
            # 19p. Linked minimum reactive power reserves (producers): zhat_qmin_beta
            if dev in idx.J_pqmin
                @constraint(model, prm.dev.q_0_lb[dev]*u_sum + 
                    prm.dev.beta_lb[dev]*dev_p[tii][dev] + 
                    q_qrd[tii][dev] - dev_q[tii][dev] <= 0)
            end

        # consumers
        else  # => dev in idx.cs_devs
            # 13c. Maximum reserve limits (consumers): zhat_pmax
            @constraint(model, p_on[tii][dev] + p_rgd[tii][dev] + p_rrd_on[tii][dev] - prm.dev.p_ub[dev][t_ind]*u_on_dev[tii][dev] <= 0)

            # 14c. Minimum reserve limits (consumers): zhat_pmin
            @constraint(model, prm.dev.p_lb[dev][t_ind]*u_on_dev[tii][dev] + p_rru_on[tii][dev] + p_scr[tii][dev] + p_rgu[tii][dev] - p_on[tii][dev] <= 0)
            
            # 15c. Off reserve limits (consumers): zhat_pmaxoff
            @constraint(model, p_su[tii][dev] + p_sd[tii][dev] + p_rrd_off[tii][dev] - prm.dev.p_ub[dev][t_ind]*(1.0 - u_on_dev[tii][dev]) <= 0)

            # get common "u_sum" terms that will be used in the subsequent four equations 
            T_supc = idx.Ts_supc[dev][t_ind] # T_supc, ~ = get_supc(tii, dev, prm) T_supc     = idx.Ts_supc[dev][t_ind] #T_supc, ~ = get_supc(tii, dev, prm)
            T_sdpc = idx.Ts_sdpc[dev][t_ind] # T_sdpc, ~ = get_sdpc(tii, dev, prm) T_sdpc, ~ = get_sdpc(tii, dev, prm)
            u_sum  = u_on_dev[tii][dev] + sum(u_su_dev[tii_inst][dev] for tii_inst in T_supc; init=0.0) + sum(u_sd_dev[tii_inst][dev] for tii_inst in T_sdpc; init=0.0)

            # 16c. Maximum reactive power reserves (consumers): zhat_qmax
            @constraint(model, dev_q[tii][dev] + q_qrd[tii][dev] - prm.dev.q_ub[dev][t_ind]*u_sum <= 0)

            # 17c. Minimum reactive power reserves (consumers): zhat_qmin
            @constraint(model, q_qru[tii][dev] + prm.dev.q_lb[dev][t_ind]*u_sum - dev_q[tii][dev] <= 0)
            
            # 18c. Linked maximum reactive power reserves (consumers): zhat_qmax_beta
            if dev in idx.J_pqmax
                @constraint(model, dev_q[tii][dev] + q_qrd[tii][dev] - prm.dev.q_0_ub[dev]*u_sum
                - prm.dev.beta_ub[dev]*dev_p[tii][dev] <= 0)
            end 

            # 19c. Linked minimum reactive power reserves (consumers): zhat_qmin_beta
            if dev in idx.J_pqmin
                @constraint(model, prm.dev.q_0_lb[dev]*u_sum
                + prm.dev.beta_lb[dev]*dev_p[tii][dev]
                + q_qru[tii][dev] - dev_q[tii][dev] <= 0)
            end
        end
    end

    # misc penalty: maximum starts over multiple periods
    for (w_ind, w_params) in enumerate(prm.dev.startups_ub[dev])
        # get the time periods: zhat_mxst
        T_su_max = idx.Ts_su_max[dev][w_ind] #get_tsumax(w_params, prm)
        @constraint(model, sum(u_su_dev[tii][dev] for tii in T_su_max; init=0.0) - w_params[3] <= 0.0)
    end

    # now, we need to add two other sorts of constraints:
    # 1. "evolutionary" constraints which link startup and shutdown variables
    for (t_ind, tii) in enumerate(prm.ts.time_keys)
        if tii == :t1
            @constraint(model, u_on_dev[tii][dev] - prm.dev.init_on_status[dev] == u_su_dev[tii][dev] - u_sd_dev[tii][dev])
        else
            tii_m1 = prm.ts.time_keys[t_ind-1]
            @constraint(model, u_on_dev[tii][dev] - u_on_dev[tii_m1][dev] == u_su_dev[tii][dev] - u_sd_dev[tii][dev])
        end
        # only one can be nonzero
        @constraint(model, u_su_dev[tii][dev] + u_sd_dev[tii][dev] <= 1)
    end

    # 2. constraints which hold constant variables from moving
        # a. must run
        # b. planned outages
        # c. pre-defined fixed values (e.g., q_qru = 0 for devs in J_pqe)
        # d. other states which are fixed from previous IBR rounds
        #       note: all of these are relfected in "upd"
    # upd = update states
    for (t_ind, tii) in enumerate(prm.ts.time_keys)
        # if a device is *not* in the set of variables,
        # then it must be held constant! -- otherwise, try to hold it
        # close to its initial value
        if dev ∉ upd[:u_on_dev][tii]
            @constraint(model, u_on_dev[tii][dev] == stt[:u_on_dev][tii][dev])
        end

        if dev ∉ upd[:p_rrd_off][tii]
            @constraint(model, p_rrd_off[tii][dev] == stt[:p_rrd_off][tii][dev])
        end

        if dev ∉ upd[:p_nsc][tii]
            @constraint(model, p_nsc[tii][dev] == stt[:p_nsc][tii][dev])
        end

        if dev ∉ upd[:p_rru_off][tii]
            @constraint(model, p_rru_off[tii][dev] == stt[:p_rru_off][tii][dev])
        end

        if dev ∉ upd[:q_qru][tii]
            @constraint(model, q_qru[tii][dev] == stt[:q_qru][tii][dev])
        end

        if dev ∉ upd[:q_qrd][tii]
            @constraint(model, q_qrd[tii][dev] == stt[:q_qrd][tii][dev])
        end

        # now, deal with reactive powers, some of which are specified with equality
        # only a subset of devices will have a reactive power equality constraint
        #
        # nothing here :)
    end
end

# now, include a "copper plate" power balance constraint
# loop over each time period and compute the power balance
for tii in prm.ts.time_keys
    # duration
    dt = prm.ts.duration[tii]

    # loop over each bus
    for bus in 1:sys.nb
        # active power balance:
        @constraint(model,
            # consumers (positive)
            sum(dev_p[tii][dev] for dev in idx.cs[bus]; init=0.0) +
            # producer (negative)
            -sum(dev_p[tii][dev] for dev in idx.pr[bus]; init=0.0) == 0.0)

        # reactive power balance:
        @constraint(model,
            # consumers (positive)
            sum(dev_q[tii][dev] for dev in idx.cs[bus]; init=0.0) +
            # producer (negative)
            -sum(dev_q[tii][dev] for dev in idx.pr[bus]; init=0.0) == 0.0)
    end
end

# ========== costs! ============= #
for (t_ind, tii) in enumerate(prm.ts.time_keys)
    # duration
    dt = prm.ts.duration[tii]

    # active power costs
    for dev in 1:sys.ndev
        # note -- these were sorted previously!
        cst = prm.dev.cum_cost_blocks[dev][t_ind][1][2:end]  # cost for each block (trim leading 0)
        pbk = prm.dev.cum_cost_blocks[dev][t_ind][2][2:end]  # power in each block (trim leading 0)
        nbk = length(pbk)

        # define a set of intermediate vars "p_jtm"
        p_jtm = @variable(model, [1:nbk], lower_bound = 0.0)
        @constraint(model, p_jtm .<= pbk)

        # have the blocks sum to the output power
        @constraint(model, sum(p_jtm) == dev_p[tii][dev])

        # compute the cost!
        zen_dev[tii][dev] = dt*sum(cst.*p_jtm)
    end
end
   
#=
# compute the costs associated with device reserve offers
for (t_ind, tii) in enumerate(prm.ts.time_keys)
    # duration
    dt = prm.ts.duration[tii]
    
    # costs
    zrgu[tii] = dt*getindex.(prm.dev.p_reg_res_up_cost,t_ind).*p_rgu[tii]
    zrgd[tii] = dt*getindex.(prm.dev.p_reg_res_down_cost,t_ind).*p_rgd[tii]
    zscr[tii] = dt*getindex.(prm.dev.p_syn_res_cost,t_ind).*p_scr[tii]
    znsc[tii] = dt*getindex.(prm.dev.p_nsyn_res_cost,t_ind).*p_nsc[tii]
    zrru[tii] = dt*(getindex.(prm.dev.p_ramp_res_up_online_cost,t_ind).*p_rru_on[tii] +
                    getindex.(prm.dev.p_ramp_res_up_offline_cost,t_ind).*p_rru_off[tii])
    zrrd[tii] = dt*(getindex.(prm.dev.p_ramp_res_down_online_cost,t_ind).*p_rrd_on[tii] +
                    getindex.(prm.dev.p_ramp_res_down_offline_cost,t_ind).*p_rrd_off[tii]) 
    zqru[tii] = dt*getindex.(prm.dev.q_res_up_cost,t_ind).*q_qru[tii]      
    zqrd[tii] = dt*getindex.(prm.dev.q_res_down_cost,t_ind).*q_qrd[tii]
end
=#

# loop over energy min/max penalties
# loop over devices, not time
# 
# initialize
for dev in 1:sys.ndev
    Wub = prm.dev.energy_req_ub[dev]
    Wlb = prm.dev.energy_req_lb[dev]

    # upper bounds
    for (w_ind, w_params) in enumerate(Wub)
        T_en_max = idx.Ts_en_max[dev][w_ind]
        zw_enmax = @variable(model)
        @constraint(model, prm.vio.e_dev*(sum(prm.ts.duration[tii]*dev_p[tii][dev] for tii in T_en_max; init=0.0) - w_params[3]) <= zw_enmax)
        add_to_expression!(z_enmax, -zw_enmax)
    end

    # lower bounds
    for (w_ind, w_params) in enumerate(Wlb)
        T_en_min = idx.Ts_en_min[dev][w_ind]
        zw_enmin = @variable(model)
        @constraint(model, prm.vio.e_dev*(w_params[3] - sum(prm.ts.duration[tii]*dev_p[tii][dev] for tii in T_en_min; init=0.0)) <= zw_enmin)
        add_to_expression!(z_enmin, -zw_enmin)
    end
end

# loop over reserves
for (t_ind, tii) in enumerate(prm.ts.time_keys)
    # duration
    dt = prm.ts.duration[tii]

    # for the "endogenous" reserve requirements
    rgu_sigma = prm.reserve.rgu_sigma
    rgd_sigma = prm.reserve.rgd_sigma 
    scr_sigma = prm.reserve.scr_sigma 
    nsc_sigma = prm.reserve.nsc_sigma  

    # loop over the zones (active power)
    for zone in 1:sys.nzP
        # endogenous sum
        if idx.cs_pzone[zone] == []
            # in the case there are NO consumers in a zone
            @constraint(model, p_rgu_zonal_REQ[tii][zone] == 0.0)
            @constraint(model, p_rgd_zonal_REQ[tii][zone] == 0.0)
        else
            @constraint(model, p_rgu_zonal_REQ[tii][zone] == rgu_sigma[zone]*sum(dev_p[tii][dev] for dev in idx.cs_pzone[zone]))
            @constraint(model, p_rgd_zonal_REQ[tii][zone] == rgd_sigma[zone]*sum(dev_p[tii][dev] for dev in idx.cs_pzone[zone]))
        end

        # endogenous max
        if idx.pr_pzone[zone] == []
            # in the case there are NO producers in a zone
            @constraint(model, pp_scr_zonal_REQ[tii][zone] == 0.0)
            @constraint(model, pp_scr_zonal_REQ[tii][zone] == 0.0)
        else
            @constraint(model, scr_sigma[zone]*[dev_p[tii][dev] for dev in idx.pr_pzone[zone]] .<= p_scr_zonal_REQ[tii][zone])
            @constraint(model, nsc_sigma[zone]*[dev_p[tii][dev] for dev in idx.pr_pzone[zone]] .<= p_nsc_zonal_REQ[tii][zone])
        end

        # balance equations -- compute the shortfall values
        @constraint(model, p_rgu_zonal_REQ[tii][zone] - 
                            sum(p_rgu[tii][dev] for dev in idx.dev_pzone[zone]; init=0.0) <= stt[:p_rgu_zonal_penalty][tii][zone])
        
        @constraint(model, p_rgd_zonal_REQ[tii][zone] - 
                            sum(p_rgd[tii][dev] for dev in idx.dev_pzone[zone]; init=0.0) <= p_rgd_zonal_penalty[tii][zone])

        @constraint(model, p_rgu_zonal_REQ[tii][zone] + 
                            p_scr_zonal_REQ[tii][zone] -
                            sum(p_rgu[tii][dev] for dev in idx.dev_pzone[zone]; init=0.0) -
                            sum(p_scr[tii][dev] for dev in idx.dev_pzone[zone]; init=0.0) <= p_scr_zonal_penalty[tii][zone])

        @constraint(model, p_rgu_zonal_REQ[tii][zone] + 
                            p_scr_zonal_REQ[tii][zone] +
                            p_nsc_zonal_REQ[tii][zone] -
                            sum(p_rgu[tii][dev] for dev in idx.dev_pzone[zone]; init=0.0) -
                            sum(p_scr[tii][dev] for dev in idx.dev_pzone[zone]; init=0.0) - 
                            sum(p_nsc[tii][dev] for dev in idx.dev_pzone[zone]; init=0.0) <= p_nsc_zonal_penalty[tii][zone])

        @constraint(model, prm.reserve.rru_min[zone][t_ind] -
                            sum(p_rru_on[tii][dev]  for dev in idx.dev_pzone[zone]; init=0.0) - 
                            sum(p_rru_off[tii][dev] for dev in idx.dev_pzone[zone]; init=0.0) <= p_rru_zonal_penalty[tii][zone])

        @constraint(model, prm.reserve.rrd_min[zone][t_ind] -
                            sum(p_rrd_on[tii][dev]  for dev in idx.dev_pzone[zone]; init=0.0) - 
                            sum(p_rrd_off[tii][dev] for dev in idx.dev_pzone[zone]; init=0.0) <= p_rrd_zonal_penalty[tii][zone])
    end

    # loop over the zones (reactive power) -- gradients are computed in the master grad
    for zone in 1:sys.nzQ
        @constraint(model, prm.reserve.qru_min[zone][t_ind] -
                            sum(q_qru[tii][dev] for dev in idx.dev_qzone[zone]; init=0.0) <= q_qru_zonal_penalty[tii][zone])

        @constraint(model, prm.reserve.qrd_min[zone][t_ind] -
                            sum(q_qrd[tii][dev] for dev in idx.dev_qzone[zone]; init=0.0) <= q_qrd_zonal_penalty[tii][zone])
    end

    # shortfall penalties -- NOT needed explicitly
        # zrgu_zonal[tii] = dt*crgu.*p_rgu_zonal_penalty[tii]
        # zrgd_zonal[tii] = dt*crgd.*p_rgd_zonal_penalty[tii]
        # zscr_zonal[tii] = dt*cscr.*p_scr_zonal_penalty[tii]
        # znsc_zonal[tii] = dt*cnsc.*p_nsc_zonal_penalty[tii]
        # zrru_zonal[tii] = dt*crru.*p_rru_zonal_penalty[tii]
        # zrrd_zonal[tii] = dt*crrd.*p_rrd_zonal_penalty[tii]
        # zqru_zonal[tii] = dt*cqru.*q_qru_zonal_penalty[tii]
        # zqrd_zonal[tii] = dt*cqrd.*q_qrd_zonal_penalty[tii]
end

# loop -- NOTE -- we are not including start-up-state discounts -- not worth it
for (t_ind, tii) in enumerate(prm.ts.time_keys)
    # duration
    dt = prm.ts.duration[tii]
    
    # add up
    zt_temp = 
        # consumer revenues (POSITIVE)
        sum(zen_dev[tii][dev] for dev in idx.cs_devs) - 
        # producer costs
        sum(zen_dev[tii][dev] for dev in idx.pr_devs) - 
        # startup costs
        sum(prm.dev.startup_cost.*u_su_dev[tii]) - 
        # shutdown costs
        sum(prm.dev.shutdown_cost.*u_sd_dev[tii]) - 
        # on-costs
        sum(dt*prm.dev.on_cost.*u_on_dev[tii]) - 
        # time-dependent su costs
        # => **** don't include for now: sum(stt[:zsus_dev][tii]) - ****
        # local reserve penalties
        sum(dt*getindex.(prm.dev.p_reg_res_up_cost,t_ind).*p_rgu[tii]) -   # zrgu
        sum(dt*getindex.(prm.dev.p_reg_res_down_cost,t_ind).*p_rgd[tii]) - # zrgd
        sum(dt*getindex.(prm.dev.p_syn_res_cost,t_ind).*p_scr[tii]) -      # zscr
        sum(dt*getindex.(prm.dev.p_nsyn_res_cost,t_ind).*p_nsc[tii]) -     # znsc
        sum(dt*(getindex.(prm.dev.p_ramp_res_up_online_cost,t_ind).*p_rru_on[tii] +
                getindex.(prm.dev.p_ramp_res_up_offline_cost,t_ind).*p_rru_off[tii])) - # zrru
        sum(dt*(getindex.(prm.dev.p_ramp_res_down_online_cost,t_ind).*p_rrd_on[tii] +
                getindex.(prm.dev.p_ramp_res_down_offline_cost,t_ind).*p_rrd_off[tii])) - # zrrd
        sum(dt*getindex.(prm.dev.q_res_up_cost,t_ind).*q_qru[tii]) -   # zqru      
        sum(dt*getindex.(prm.dev.q_res_down_cost,t_ind).*q_qrd[tii]) - # zqrd
        # zonal reserve penalties (P)
        sum(dt*prm.vio.rgu_zonal.*p_rgu_zonal_penalty[tii]) -
        sum(dt*prm.vio.rgd_zonal.*p_rgd_zonal_penalty[tii]) -
        sum(dt*prm.vio.scr_zonal.*p_scr_zonal_penalty[tii]) -
        sum(dt*prm.vio.nsc_zonal.*p_nsc_zonal_penalty[tii]) -
        sum(dt*prm.vio.rru_zonal.*p_rru_zonal_penalty[tii]) -
        sum(dt*prm.vio.rrd_zonal.*p_rrd_zonal_penalty[tii]) -
        # zonal reserve penalties (Q)
        sum(dt*prm.vio.qru_zonal.*q_qru_zonal_penalty[tii]) -
        sum(dt*prm.vio.qrd_zonal.*q_qrd_zonal_penalty[tii])

    # update zt
    add_to_expression!(zt, zt_temp)
end

# define the objective
zms_partial = zt + z_enmax + z_enmin

# set the objective
@objective(model, Max, zms_partial)

# solve
optimize!(model)