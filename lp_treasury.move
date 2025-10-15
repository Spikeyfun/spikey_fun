module spike_fun::LPStorage {
    use std::signer;
    use supra_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use supra_framework::object::{Self, Object};
    use supra_framework::primary_fungible_store;
    use supra_framework::table::{Self, Table};
    use spike_amm::amm_factory;
    use spike_amm::amm_router;
    use spike_amm::amm_oracle;
    use std::error;
    use supra_framework::timestamp;
    use aptos_std::math128;
    use supra_framework::account;
    use std::option::{Self, Option};
    use supra_framework::event;

    friend spike_fun::spike_fun;

    const ERROR_ONLY_ADMIN: u64 = 1;
    const ERROR_PACT_NOT_RESOLVED_YET: u64 = 2;
    const ERROR_PACT_ALREADY_RESOLVED: u64 = 3;
    const ERROR_INVALID_POOL_INFO: u64 = 4;
    const ERROR_ALREADY_INITIALIZED: u64 = 5;
    const ERROR_PROPOSAL_PENDING: u64 = 6;
    const ERROR_NO_PROPOSAL_PENDING: u64 = 7;
    const ERROR_TIMELOCK_NOT_EXPIRED: u64 = 8;
    const ERROR_GRACE_PERIOD_NOT_OVER: u64 = 9;
    const ERROR_INVALID_TIMELOCK_DELAY: u64 = 10;
    const ERROR_INVALID_ORACLE_PRICE: u64 = 11;

    const MIN_TIMELOCK_DELAY: u64 = 86400; // 1 day in seconds
    const MAX_TIMELOCK_DELAY: u64 = 2_592_000; // 30 days in seconds
    const BURN_ADDRESS: address = @0x1;
    const ADMIN_GRACE_PERIOD: u64 = 2_592_000;
    const LIQUIDITY_LOCK_DURATION: u64 = 31_536_000;
    const K_STABILITY_RANGE_BPS: u128 = 1370;
    const STABILITY_RANGE_BPS: u128 = 2000;
    const PRICE_PRECISION: u128 = 1_000_000_000;

    const MODULE_ADMIN: address = @lp_treasury;

    struct Config has key {
       admin_address: address,
    }

    struct PendingAdminChange has store, drop, copy {
        new_admin_address: address,
        eta: u64,
    }

    struct Admin has key {
        admin: address,
        treasury_cap: account::SignerCapability,
        pending_admin_proposal: Option<PendingAdminChange>,
        timelock_delay_seconds: u64,
    }

    struct LiquidityPoolData has key {
        pools: Table<address, PoolInfo>,
    }

    struct PoolInfo has store {
        token_x: address,
        token_y: address,
        principal_lp_balance: u64,
        deposit_timestamp: u64,
        reference_price: u128,
        is_resolved: bool,
    }

    struct EventHandles has key {
        pact_deposited_events: event::EventHandle<PactDeposited>,
        pact_resolved_events: event::EventHandle<PactResolved>,
        pact_force_resolved_events: event::EventHandle<PactForceResolved>,
        admin_change_queued_events: event::EventHandle<AdminChangeQueued>,
        admin_change_executed_events: event::EventHandle<AdminChangeExecuted>,
        admin_change_canceled_events: event::EventHandle<AdminChangeCanceled>,
    }

    #[event]
    struct PactDeposited has drop, store {
        lp_token_address: address,
        token_x: address,
        token_y: address,
        lp_amount: u64,
        reference_price: u128,
        timestamp: u64,
    }

    #[event]
    struct PactResolved has drop, store {
        resolver: address,
        lp_token_address: address,
        was_stable: bool,
        admin_share_amount: u64,
        burned_share_amount: u64,
        timestamp: u64,
    }

    #[event]
    struct PactForceResolved has drop, store {
        resolver: address,
        lp_token_address: address,
        burned_amount: u64,
        timestamp: u64,
    }
    
    #[event]
    struct AdminChangeQueued has drop, store {
        proposer: address,
        new_admin_address: address,
        eta: u64,
    }

    #[event]
    struct AdminChangeExecuted has drop, store {
        executor: address,
        old_admin: address,
        new_admin: address,
    }

    #[event]
    struct AdminChangeCanceled has drop, store {
        canceller: address,
    }

    fun init_module(account: &signer) {
        let owner = signer::address_of(account);
        assert!(!exists<Config>(owner), error::already_exists(ERROR_ALREADY_INITIALIZED));
        
        let (treasury_account, treasury_cap) = account::create_resource_account(account, b"lp_treasury_main");
        let treasury_signer = &treasury_account;

        move_to(account, Config {
            admin_address: owner,
        });

        move_to(treasury_signer, LiquidityPoolData {
            pools: table::new(),
        });
        
        move_to(account, Admin {
            admin: owner,
            treasury_cap,
            pending_admin_proposal: option::none(),
            timelock_delay_seconds: 172800,
        });
        
        move_to(account, EventHandles {
            pact_deposited_events: account::new_event_handle<PactDeposited>(account),
            pact_resolved_events: account::new_event_handle<PactResolved>(account),
            pact_force_resolved_events: account::new_event_handle<PactForceResolved>(account),
            admin_change_queued_events: account::new_event_handle<AdminChangeQueued>(account),
            admin_change_executed_events: account::new_event_handle<AdminChangeExecuted>(account),
            admin_change_canceled_events: account::new_event_handle<AdminChangeCanceled>(account),
        });
    }

    public(friend) fun deposit_lp(
        lp_token_metadata: Object<Metadata>,
        lp_tokens: FungibleAsset,
        token_x: address,
        token_y: address,
        amount_x_deposited: u64,
        amount_y_deposited: u64
    ) acquires Config, LiquidityPoolData, Admin, EventHandles {
        assert!(amount_y_deposited > 0, error::invalid_argument(ERROR_INVALID_ORACLE_PRICE));
        assert!(amount_x_deposited > 0, error::invalid_argument(ERROR_INVALID_ORACLE_PRICE));
        let admin_addr = borrow_global<Config>(MODULE_ADMIN).admin_address;
        let admin_struct = borrow_global<Admin>(admin_addr);
        let treasury_address = account::get_signer_capability_address(&admin_struct.treasury_cap);
        primary_fungible_store::ensure_primary_store_exists(treasury_address, lp_token_metadata);

        let lp_amount = fungible_asset::amount(&lp_tokens);
        primary_fungible_store::deposit(treasury_address, lp_tokens);

        let reference_price = math128::mul_div(
            (amount_y_deposited as u128), 
            PRICE_PRECISION, 
            (amount_x_deposited as u128)
        );

        let lp_token_address = object::object_address(&lp_token_metadata);
        let data = borrow_global_mut<LiquidityPoolData>(treasury_address);

        if (table::contains(&data.pools, lp_token_address)) {
            let pool_info = table::borrow_mut(&mut data.pools, lp_token_address);
            pool_info.principal_lp_balance = pool_info.principal_lp_balance + lp_amount;
        } else {
            table::add(&mut data.pools, lp_token_address, PoolInfo {
                token_x,
                token_y,
                principal_lp_balance: lp_amount,
                deposit_timestamp: timestamp::now_seconds(),
                reference_price,
                is_resolved: false,
            });
        };
        
        event::emit_event(
            &mut borrow_global_mut<EventHandles>(admin_addr).pact_deposited_events,
            PactDeposited {
                lp_token_address,
                token_x,
                token_y,
                lp_amount,
                reference_price,
                timestamp: timestamp::now_seconds(),
            }
        );
    }

    public entry fun resolve_liquidity_pact(
        signer: &signer, 
        lp_token_address: address
    ) acquires Config, LiquidityPoolData, Admin, EventHandles {
        let admin_addr = borrow_global<Config>(MODULE_ADMIN).admin_address;
        let caller = signer::address_of(signer);
        let admin_resource = borrow_global<Admin>(admin_addr);
        assert!(caller == admin_resource.admin, error::permission_denied(ERROR_ONLY_ADMIN));

        let treasury_signer = account::create_signer_with_capability(&admin_resource.treasury_cap);
        let treasury_address = signer::address_of(&treasury_signer);

        let data = borrow_global_mut<LiquidityPoolData>(treasury_address);
        assert!(table::contains(&data.pools, lp_token_address), error::invalid_state(ERROR_INVALID_POOL_INFO));

        let pool_info = table::borrow_mut(&mut data.pools, lp_token_address);
        assert!(!pool_info.is_resolved, error::invalid_state(ERROR_PACT_ALREADY_RESOLVED));
        assert!(
            timestamp::now_seconds() >= pool_info.deposit_timestamp + LIQUIDITY_LOCK_DURATION,
            error::permission_denied(ERROR_PACT_NOT_RESOLVED_YET)
        );

        let token_x_obj = object::address_to_object<Metadata>(pool_info.token_x);
        let token_y_obj = object::address_to_object<Metadata>(pool_info.token_y);

        amm_oracle::update(token_x_obj, token_y_obj);
        let current_price_x_in_anchor = amm_oracle::get_average_price_v2(token_x_obj);
        let current_price_y_in_anchor = amm_oracle::get_average_price_v2(token_y_obj);
        let current_average_price = if (current_price_y_in_anchor > 0) { 
            math128::mul_div(current_price_x_in_anchor, PRICE_PRECISION, current_price_y_in_anchor)
        } else { 0 };

        let reference_price = pool_info.reference_price;
        let lower_bound = math128::mul_div(reference_price, 10000 - STABILITY_RANGE_BPS, 10000);
        let upper_bound = math128::mul_div(reference_price, 10000 + STABILITY_RANGE_BPS, 10000);

        let lp_token_metadata = object::address_to_object<Metadata>(lp_token_address);
        let total_lp_to_resolve = pool_info.principal_lp_balance;

        pool_info.is_resolved = true;
        pool_info.principal_lp_balance = 0;

        let was_stable = false;
        let admin_share = 0;
        let burn_share: u64;

        if (current_average_price >= lower_bound && current_average_price <= upper_bound) {
            was_stable = true;
            admin_share = total_lp_to_resolve / 2;
            burn_share = total_lp_to_resolve - admin_share;

            if (admin_share > 0) {
                let admin_lps = primary_fungible_store::withdraw(&treasury_signer, lp_token_metadata, admin_share);
                primary_fungible_store::deposit(caller, admin_lps);
            };
            if (burn_share > 0) {
                let burn_lps = primary_fungible_store::withdraw(&treasury_signer, lp_token_metadata, burn_share);
                primary_fungible_store::deposit(BURN_ADDRESS, burn_lps);
            };
        } else {
            burn_share = total_lp_to_resolve;
            if (burn_share > 0) {
                let burn_lps = primary_fungible_store::withdraw(&treasury_signer, lp_token_metadata, burn_share);
                primary_fungible_store::deposit(BURN_ADDRESS, burn_lps);
            };
        };
        
        event::emit_event(
            &mut borrow_global_mut<EventHandles>(admin_addr).pact_resolved_events,
            PactResolved {
                resolver: caller,
                lp_token_address,
                was_stable,
                admin_share_amount: admin_share,
                burned_share_amount: burn_share,
                timestamp: timestamp::now_seconds(),
            }
        );
    }

    public entry fun queue_new_admin(account: &signer, new_admin_address: address) acquires Config, Admin, EventHandles {
        let admin_addr = borrow_global<Config>(MODULE_ADMIN).admin_address;
        let caller_address = signer::address_of(account);
        let admin_resource = borrow_global_mut<Admin>(admin_addr);
        assert!(caller_address == admin_resource.admin, error::permission_denied(ERROR_ONLY_ADMIN));
        
        let eta = timestamp::now_seconds() + admin_resource.timelock_delay_seconds;
        admin_resource.pending_admin_proposal = option::some(PendingAdminChange {
            new_admin_address,
            eta,
        });

        event::emit_event(
            &mut borrow_global_mut<EventHandles>(admin_addr).admin_change_queued_events,
            AdminChangeQueued {
                proposer: caller_address,
                new_admin_address,
                eta,
            }
        );
    }

    public entry fun execute_new_admin(account: &signer) acquires Config, Admin, EventHandles {
        let admin_addr = borrow_global<Config>(MODULE_ADMIN).admin_address;
        let executor = signer::address_of(account);
        let admin_resource = borrow_global_mut<Admin>(admin_addr);
        assert!(option::is_some(&admin_resource.pending_admin_proposal), error::not_found(ERROR_NO_PROPOSAL_PENDING));

        let proposal_ref = option::borrow(&admin_resource.pending_admin_proposal);
        assert!(timestamp::now_seconds() >= proposal_ref.eta, error::permission_denied(ERROR_TIMELOCK_NOT_EXPIRED));

        let old_admin = admin_resource.admin;
        let proposal = option::extract(&mut admin_resource.pending_admin_proposal);
        
        admin_resource.admin = proposal.new_admin_address;

        event::emit_event(
            &mut borrow_global_mut<EventHandles>(admin_addr).admin_change_executed_events,
            AdminChangeExecuted {
                executor,
                old_admin,
                new_admin: proposal.new_admin_address,
            }
        );
    }

    public entry fun cancel_admin_proposal(account: &signer) acquires Config, Admin, EventHandles {
        let admin_addr = borrow_global<Config>(MODULE_ADMIN).admin_address;
        let caller_address = signer::address_of(account);
        let admin_resource = borrow_global_mut<Admin>(admin_addr);
        assert!(caller_address == admin_resource.admin, error::permission_denied(ERROR_ONLY_ADMIN));
        assert!(option::is_some(&admin_resource.pending_admin_proposal), error::not_found(ERROR_NO_PROPOSAL_PENDING));

        admin_resource.pending_admin_proposal = option::none();

        event::emit_event(
            &mut borrow_global_mut<EventHandles>(admin_addr).admin_change_canceled_events,
            AdminChangeCanceled {
                canceller: caller_address,
            }
        );
    }

    public entry fun set_timelock_delay(account: &signer, new_delay_seconds: u64) acquires Config, Admin {
        let admin_addr = borrow_global<Config>(MODULE_ADMIN).admin_address;
        let caller_address = signer::address_of(account);
        let admin_resource = borrow_global_mut<Admin>(admin_addr);
        assert!(caller_address == admin_resource.admin, error::permission_denied(ERROR_ONLY_ADMIN));
        assert!(new_delay_seconds >= MIN_TIMELOCK_DELAY && new_delay_seconds <= MAX_TIMELOCK_DELAY, error::invalid_argument(ERROR_INVALID_TIMELOCK_DELAY));
        admin_resource.timelock_delay_seconds = new_delay_seconds;
    }

    public entry fun force_resolve_abandoned_pact(
        signer: &signer,
        lp_token_address: address
    ) acquires Config, LiquidityPoolData, Admin, EventHandles {
        let admin_addr = borrow_global<Config>(MODULE_ADMIN).admin_address;
        let resolver = signer::address_of(signer);
        let admin_resource = borrow_global<Admin>(admin_addr);
        let treasury_signer = account::create_signer_with_capability(&admin_resource.treasury_cap);
        let treasury_address = signer::address_of(&treasury_signer);

        let data = borrow_global_mut<LiquidityPoolData>(treasury_address);
        assert!(table::contains(&data.pools, lp_token_address), error::invalid_state(ERROR_INVALID_POOL_INFO));

        let pool_info = table::borrow_mut(&mut data.pools, lp_token_address);
        assert!(!pool_info.is_resolved, error::invalid_state(ERROR_PACT_ALREADY_RESOLVED));

        let force_deadline = pool_info.deposit_timestamp + LIQUIDITY_LOCK_DURATION + ADMIN_GRACE_PERIOD;
        assert!(
            timestamp::now_seconds() >= force_deadline,
            error::permission_denied(ERROR_GRACE_PERIOD_NOT_OVER)
        );
        
        let total_lp_to_burn = pool_info.principal_lp_balance;
        
        pool_info.is_resolved = true;
        pool_info.principal_lp_balance = 0;

        if (total_lp_to_burn > 0) {
            let lp_token_metadata = object::address_to_object<Metadata>(lp_token_address);
            let burn_lps = primary_fungible_store::withdraw(&treasury_signer, lp_token_metadata, total_lp_to_burn);
            primary_fungible_store::deposit(BURN_ADDRESS, burn_lps);
        };

        event::emit_event(
            &mut borrow_global_mut<EventHandles>(admin_addr).pact_force_resolved_events,
            PactForceResolved {
                resolver,
                lp_token_address,
                burned_amount: total_lp_to_burn,
                timestamp: timestamp::now_seconds(),
            }
        );
    }

    #[view]
    public fun get_pool_info(lp_token_address: address): (address, address, u64, u64, u128, bool) 
    acquires Config, LiquidityPoolData, Admin {
        let admin_addr = borrow_global<Config>(MODULE_ADMIN).admin_address;
        let admin_struct = borrow_global<Admin>(admin_addr);
        let treasury_address = account::get_signer_capability_address(&admin_struct.treasury_cap);
        let data = borrow_global<LiquidityPoolData>(treasury_address);
        assert!(table::contains(&data.pools, lp_token_address), error::invalid_state(ERROR_INVALID_POOL_INFO));
        let pool_info = table::borrow(&data.pools, lp_token_address);
        (
            pool_info.token_x,
            pool_info.token_y,
            pool_info.principal_lp_balance,
            pool_info.deposit_timestamp,
            pool_info.reference_price,
            pool_info.is_resolved
        )
    }

    #[view]
    public fun get_pair_balances(token_x: address, token_y: address, owner: address): (u64, u64) {
        let lp_token_address = amm_factory::get_pair(token_x, token_y);
        let lp_token_metadata = object::address_to_object<Metadata>(lp_token_address);
        let liquidity = primary_fungible_store::balance(owner, lp_token_metadata);
        if (liquidity == 0) {
            return (0, 0)
        };
        amm_router::view_remove_liquidity(token_x, token_y, liquidity)
    }
}