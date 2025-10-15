module spike_fun::spike_fun {
    use aptos_std::simple_map::{Self, SimpleMap};
    use std::error;
    use std::signer::address_of;
    use std::string::{Self, String};
    use std::option::{Self, Option};
    use aptos_std::math64;
    use aptos_std::math128;
    use aptos_std::type_info::type_name;
    use supra_framework::account;
    use supra_framework::account::SignerCapability;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::coin;
    use supra_framework::coin::Coin;
    use supra_framework::event;
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use supra_framework::fungible_asset::{Self, Metadata};
    use supra_framework::object::{Self};
    use spike_fun::asset_manager;
    use spike_amm::amm_router;
    //use amm::amm_factory;
    use spike_amm::coin_wrapper;
    use lp_treasury::LPStorage;
    use spike_fun::hodl_fa;

    const ERROR_INVALID_LENGTH: u64 = 1;
    const ERROR_NO_AUTH: u64 = 2;
    const ERROR_INITIALIZED: u64 = 3;
    const ERROR_PUMP_NOT_EXIST: u64 = 6;
    const ERROR_PUMP_COMPLETED: u64 = 7;
    const ERROR_PUMP_AMOUNT_IS_NULL: u64 = 8;
    const ERROR_PUMP_AMOUNT_TO_LOW: u64 = 9;
    const ERROR_TOKEN_DECIMAL: u64 = 10;
    const ERROR_INSUFFICIENT_LIQUIDITY: u64 = 11;
    const ERROR_SLIPPAGE_TOO_HIGH: u64 = 12;
    const ERROR_OVERFLOW: u64 = 13;
    const ERROR_PUMP_NOT_COMPLETED: u64 = 14;
    const ERROR_INSUFFICIENT_BALANCE: u64 = 18;
    const ERROR_FEE_TOO_HIGH: u64 = 19;
    const ERROR_AMOUNT_TOO_LOW: u64 = 20;
    const ERROR_INVALID_RAISE: u64 = 22;
    const ERROR_OUT_OF_THE_RANGE: u64 = 23;
    const ERROR_INVALID_RAISE_LIMITS: u64 = 24;
    const ERROR_MIGRATION_STATE_INCONSISTENCY: u64 = 25;
    const ERROR_VIRTUAL_PRICE_CANNOT_BE_ZERO: u64 = 26;
    const ERROR_INVALID_UNSTAKE_PERIOD: u64 = 32;

    const DECIMALS: u64 = 100_000_000; //DECIMALS FUNGIBLE ASSETS
    const U64_MAX_AS_U128: u128 = 18446744073709551615u128; //MAX VALUE FOR U64
    const U128_MAX: u128 = 340282366920938463463374607431768211455u128; //MAX VALUE FOR U128
    const MAX_PLATFORM_FEE_BPS: u64 = 300; // 3% MAX PLATFORM FEE *
    const MIN_UNSTAKE_PERIOD: u64 = 2_592_000; // 30 days MIN UNSTAKE PERIOD *
    const MAX_UNSTAKE_PERIOD: u64 = 31_536_000; // 1 year MAX UNSTAKE PERIOD *
    const MAX_CREATOR_FEE_BPS: u64 = 300; // 3% MAX CREATOR FEE *
    const MAX_MIGRATOR_REWARD_BPS: u64 = 300; // 3% MAX MIGRATOR REWARD *
    const MAX_VIRTUAL_MULTIPLIER: u64 = 1000; // (SUPRA in Virtual Pool) / (SUPRA in Fundraising Goal)
    const MIN_VIRTUAL_MULTIPLIER: u64 = 10; //(SUPRA in Virtual Pool) / (SUPRA in Fundraising Goal)
    const MAX_RAISING_PERCENTAGE: u64 = 5000; // max 50% raising goes to devs *
    const MAX_TOKEN_DECIMALS: u8 = 18;
    const MIN_TOKEN_DECIMALS: u8 = 6;
    const SUPPLY_DEVIATION_TOLERANCE_BPS: u64 = 2000; // 20%    
    const MAX_SUPPLY_DEVIATION_TOLERANCE_BPS: u64 = 5000; // 50% max

    const MODULE_ADMIN: address = @spike_fun;
    const HODL_FA_ADDR: address = @spike_fun;

    struct PumpConfig has key, store {
        creator_fee_bps: u64,
        platform_fee: u64,
        deploy_fee: u64,
        resource_cap: SignerCapability,
        platform_fee_address: address,
        benefitiary_address_for_excess: address,
        raise_limit_min: u64,
        raise_limit_max: u64,
        staking_rate: u64,
        virtual_mult_range_meme: u64,
        virtual_mult_range_DAO: u64,
        virtual_mult_range_BIG_DAO: u64, 
        tokens_per_sup: u64,
        raising_percentage_meme: u64,
        raising_percentage_DAO: u64,
        raising_percentage_BIG_DAO: u64,
        token_decimals: u8,
        min_trade_supra_amount: u64,
        deadline: u64,
        unstake_period_seconds_default: u64,
        unstake_period_seconds_min: u64,
        unstake_period_seconds_max: u64,
        migrator_reward_bps: u64,
        migration_gas_amount: u64,
        migration_slippage_bps: u64,
        supply_deviation_tolerance_bps: u64,
    }

    struct UpdateConfigArgs has store, drop, copy {
        new_raise_limit_min: u64,
        new_raise_limit_max: u64,
        new_staking_rate: u64,
        new_virtual_mult_range_meme: u64,
        new_virtual_mult_range_DAO: u64,
        new_virtual_mult_range_BIG_DAO: u64,
        new_tokens_per_sup: u64, 
        new_raising_percentage_meme: u64,
        new_raising_percentage_DAO: u64,
        new_raising_percentage_BIG_DAO: u64, 
        new_token_decimals: u8,
        new_min_trade_supra_amount: u64,
        new_deadline: u64,
        new_unstake_period_seconds_default: u64,
        new_migrator_reward_bps: u64,
        new_migration_gas_amount: u64,
        new_creator_fee_bps: u64,
        new_platform_fee: u64
    }

    struct Pool has key, store, copy, drop {
        initial_virtual_token_supply: u128,
        initial_virtual_supra_reserves: u128,
        virtual_token_reserves: u128,
        virtual_supra_reserves: u128,
        target_supra_dex_threshold: u64,
        raising_percent: u64,
        is_completed: bool,
        is_migrated_to_dex: bool,
        dev: address,
        migration_snapshot_v_token_reserves: u128,
        migration_snapshot_v_supra_reserves: u128,
    }

    struct TokenPairRecord has key, store {
        name: String,
        symbol: String,
        pool: Pool
    }

    struct PoolRecord has key, store {
        records: SimpleMap<address, TokenPairRecord>,
        real_supra_reserves: SimpleMap<address, Coin<SupraCoin>>,
    }

    struct MigrationRewards has store, drop, copy {
        dev_reward: u64,
        staking_reward: u64,
        migrator_reward: u64,
    }

    struct Handle has key {
        created_events: event::EventHandle<PumpEvent>,
        trade_events: event::EventHandle<TradeEvent>,
        unfreeze_events: event::EventHandle<UnfreezeEvent>,
        proposal_queued_events: event::EventHandle<ProposalQueued>,
        proposal_executed_events: event::EventHandle<ProposalExecuted>,
        proposal_canceled_events: event::EventHandle<ProposalCanceled>,
        migration_events: event::EventHandle<MigrationToAmmEvent>,
    }

    struct PendingProposal has store, key, drop {
        proposer: address,
        eta: u64,
        new_creator_fee_bps: u64,
        new_platform_fee: u64,
        new_deploy_fee: u64,
        new_platform_fee_address: address,
        new_benefitiary_address_for_excess: address,
        new_raise_limit_min: u64,
        new_raise_limit_max: u64,
        new_staking_rate: u64,
        new_virtual_mult_range_meme: u64,
        new_virtual_mult_range_DAO: u64,
        new_virtual_mult_range_BIG_DAO: u64, 
        new_tokens_per_sup: u64,
        new_raising_percentage_meme: u64,
        new_raising_percentage_DAO: u64,
        new_raising_percentage_BIG_DAO: u64,
        new_token_decimals: u8,
        new_min_trade_supra_amount: u64,
        new_deadline: u64,
        new_unstake_period_seconds_default: u64,
        new_unstake_period_seconds_min: u64,
        new_unstake_period_seconds_max: u64,
        new_migrator_reward_bps: u64,
        new_migration_gas_amount: u64,
        new_supply_deviation_tolerance_bps: u64
    }

    struct TimelockState has key {
        pending_proposal: Option<PendingProposal>,
        delay: u64,
        admin: address,
    }

    struct LaunchParameters has drop {
        raise_limit_min: u64,
        raise_limit_max: u64,
        virtual_mult_range_meme: u64,
        virtual_mult_range_DAO: u64,
        virtual_mult_range_BIG_DAO: u64,
        tokens_per_sup: u64,
        raising_percentage_meme_bps: u64,
        raising_percentage_DAO_bps: u64,
        raising_percentage_BIG_DAO_bps: u64,
        unstake_period_seconds_default: u64,
        unstake_period_seconds_min: u64,
        unstake_period_seconds_max: u64,
        default_token_decimals: u8,
        staking_rate: u64,
    }

    struct ProtocolFees has drop {
        swap_platform_fee_bps: u64,
        swap_creator_fee_bps: u64,
        deploy_fee: u64,
        migrator_reward_bps: u64,
        migration_gas_fee: u64,        
        platform_fee_address: address,
        benefitiary_address_for_excess: address,
        min_trade_supra_amount: u64,
        migration_slippage_bps: u64,
    }

    struct PoolStateView has drop {
        virtual_token_reserves: u128,
        virtual_supra_reserves: u128,
        is_completed: bool,
        is_migrated_to_dex: bool,
        target_supra_dex_threshold: u64,
        dev_address: address,
    }

    #[event]
    struct PumpEvent has drop, store {
        project_type: String,
        pool: String,
        dev: address,
        description: String,
        name: String,
        symbol: String,
        token_address: address,
        uri: String,
        website: String,
        telegram: String,
        twitter: String,
        github: String,
        stream: String,
        platform_fee: u64,
        initial_virtual_token_reserves: u128,
        initial_virtual_supra_reserves: u128,
        token_decimals: u8,
        unstake_period_seconds: u64
    }

    #[event]
    struct TradeEvent has drop, store {
        supra_amount: u64,
        is_buy: bool,
        token_address: address,
        token_amount: u64,
        user: address,
        virtual_supra_reserves: u128,
        virtual_token_reserves: u128,
        timestamp: u64,
        platform_fee: u64,
        creator_fee: u64,
    }

    #[event]
    struct MigrationToAmmEvent has drop, store {
        token_address: address,
        migrator: address,
        supra_sent_to_lp: u64,
        tokens_sent_to_lp: u64,
        dev_reward_staked: u64,
        staking_pool_reward: u64,
        migrator_reward: u64,
        excess_supra_collected: u64,
    }

    #[event]
    struct UnfreezeEvent has drop, store {
        token_address: String,
        user: address
    }

    #[event]
    struct ProposalExecuted has drop, store {
        executor: address,
        eta: u64,
    }

    #[event]
    struct ProposalCanceled has drop, store {
        canceller: address,
    }

    #[event]
    struct ProposalQueued has drop, store {
        proposer: address,
        eta: u64,
        target_function: String,
    }

    fun get_validated_pool_key(
        token_address: address,
    ): hodl_fa::PoolIdentifier acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);

        let pool_record = borrow_global<PoolRecord>(resource_addr);
        assert!(
            simple_map::contains_key(&pool_record.records, &token_address),
            error::not_found(ERROR_PUMP_NOT_EXIST)
        );

        hodl_fa::new_pool_identifier(
            resource_addr,
            token_address,
            token_address
        )
    }

    fun register_if_needed(caller: &signer, token_address: address) {
        let sender = address_of(caller);

        if (!coin::is_account_registered<SupraCoin>(sender)) {
            coin::register<SupraCoin>(caller);
        };

        let token_metadata_obj = object::address_to_object<Metadata>(token_address);
        if (!primary_fungible_store::primary_store_exists(sender, token_metadata_obj)) {
            primary_fungible_store::create_primary_store(sender, token_metadata_obj);
        };
    }

    fun calculate_add_liquidity_cost(
        supra_reserves: u128,
        token_reserves: u128,
        token_amount: u128
    ): u128 {
        assert!(supra_reserves > 0 && token_reserves > 0 && token_amount > 0, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));
        assert!(token_reserves > token_amount, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));
        
        let numerator_u256 = (supra_reserves as u256) * (token_reserves as u256);
        let denominator_u256 = (token_reserves as u256) - (token_amount as u256);
        let new_supra_reserves_u256 = (numerator_u256 + denominator_u256 - 1) / denominator_u256;
        let cost_u256 = new_supra_reserves_u256 - (supra_reserves as u256);

        assert!(cost_u256 <= (U128_MAX as u256), error::invalid_argument(ERROR_OVERFLOW));

        (cost_u256 as u128)
    }

    fun calculate_sell_token(
        token_reserves: u128,
        supra_reserves: u128,
        token_value: u128
    ): u128 {
        assert!(token_reserves > 0 && supra_reserves > 0 && token_value > 0, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));

        let numerator_u256 = (token_reserves as u256) * (supra_reserves as u256);
        let denominator_u256 = (token_value as u256) + (token_reserves as u256);
        let remaining_supra_reserves_u256 = numerator_u256 / denominator_u256;

        let result_u256 = (supra_reserves as u256) - remaining_supra_reserves_u256;

        assert!(result_u256 <= (U128_MAX as u256), error::invalid_argument(ERROR_OVERFLOW));

        (result_u256 as u128)
    }

    fun calculate_buy_token(
        token_reserves: u128,
        supra_reserves: u128,
        supra_value: u128
    ): u128 {
        assert!(token_reserves > 0 && supra_reserves > 0 && supra_value > 0, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));

        let numerator_u256 = (token_reserves as u256) * (supra_value as u256);
        let denominator_u256 = (supra_reserves as u256) + (supra_value as u256);
        let result_u256 = numerator_u256 / denominator_u256;

        assert!(result_u256 <= (U128_MAX as u256), error::invalid_argument(ERROR_OVERFLOW));

        (result_u256 as u128)
    }
    fun get_token_by_sup(pool: &mut Pool, supra_in_amount: u128, token_out_amount: u128) {
        assert!(token_out_amount <= pool.virtual_token_reserves, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));
        assert!(token_out_amount > 0 && supra_in_amount > 0, error::invalid_argument(ERROR_PUMP_AMOUNT_IS_NULL));
        
        pool.virtual_supra_reserves = pool.virtual_supra_reserves + supra_in_amount;
        pool.virtual_token_reserves = pool.virtual_token_reserves - token_out_amount;   
    }

    fun get_sup_by_token(pool: &mut Pool, token_in_amount: u128, supra_out_amount: u128) {
        assert!(supra_out_amount <= pool.virtual_supra_reserves, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));
        assert!(token_in_amount > 0 && supra_out_amount > 0, error::invalid_argument(ERROR_PUMP_AMOUNT_IS_NULL));

        pool.virtual_token_reserves = pool.virtual_token_reserves + token_in_amount;
        pool.virtual_supra_reserves = pool.virtual_supra_reserves - supra_out_amount;
    }

    fun prepare_for_migration(
        token_pair_record: &mut TokenPairRecord,
    ) acquires PumpConfig {
        let pool = &mut token_pair_record.pool;
        assert!(!pool.is_completed, error::invalid_state(ERROR_PUMP_COMPLETED));

        pool.is_completed = true;
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);

        let ideal_circulating_supply = calculate_ideal_projected_supply_base(
            pool.initial_virtual_token_supply,
            pool.initial_virtual_supra_reserves,
            pool.target_supra_dex_threshold
        );

        let real_circulating_supply = pool.initial_virtual_token_supply - pool.virtual_token_reserves;

        let lower_bound_supply = math128::mul_div(ideal_circulating_supply, 10000 - (config.supply_deviation_tolerance_bps as u128), 10000);
        let upper_bound_supply = math128::mul_div(ideal_circulating_supply, 10000 + (config.supply_deviation_tolerance_bps as u128), 10000);

        let capped_supply = math128::min(real_circulating_supply, upper_bound_supply);
        let effective_circulating_supply = math128::max(capped_supply, lower_bound_supply);

        let effective_v_token_reserves = pool.initial_virtual_token_supply - effective_circulating_supply;
        
        let k_invariant = (pool.initial_virtual_token_supply as u256) * (pool.initial_virtual_supra_reserves as u256);
        let effective_v_supra_reserves_u256 = k_invariant / (effective_v_token_reserves as u256);
        assert!(effective_v_supra_reserves_u256 <= (U128_MAX as u256), error::invalid_argument(ERROR_OVERFLOW));
        let effective_v_supra_reserves = (effective_v_supra_reserves_u256 as u128);

        pool.migration_snapshot_v_token_reserves = effective_v_token_reserves;
        pool.migration_snapshot_v_supra_reserves = effective_v_supra_reserves;
    }

    fun init_module(pump_admin: &signer) {
        assert!(address_of(pump_admin) == MODULE_ADMIN, error::permission_denied(ERROR_NO_AUTH));
        assert!(!exists<PumpConfig>(address_of(pump_admin)), error::already_exists(ERROR_INITIALIZED));

        let (resource_account, signer_cap) =
            account::create_resource_account(pump_admin, b"pump");
        move_to(
            pump_admin,
            Handle {
                created_events: account::new_event_handle<PumpEvent>(pump_admin),
                trade_events: account::new_event_handle<TradeEvent>(pump_admin),
                unfreeze_events: account::new_event_handle<UnfreezeEvent>(pump_admin),
                proposal_queued_events: account::new_event_handle<ProposalQueued>(pump_admin),
                proposal_executed_events: account::new_event_handle<ProposalExecuted>(pump_admin),
                proposal_canceled_events: account::new_event_handle<ProposalCanceled>(pump_admin),
                migration_events: account::new_event_handle<MigrationToAmmEvent>(pump_admin), 

            }
        );
        move_to(
            pump_admin,
            PumpConfig {
                creator_fee_bps: 30, //0.3% creator fee
                platform_fee: 40, //0.4% platform fee
                deploy_fee: 1 * DECIMALS, //1 SUPRA deploy fee
                platform_fee_address: MODULE_ADMIN,
                benefitiary_address_for_excess: MODULE_ADMIN,
                resource_cap: signer_cap,
                staking_rate: 1000,
                raise_limit_min: 13_700_000_000, //min virtual pool amount size in supra
                raise_limit_max: 274_000_000_000,//max virtual pool amount size in supra
                virtual_mult_range_meme: 130, //A value of 130 means that for every 1 SUPRA the project aims to raise, the contract will create 130 SUPRA of virtual liquidity. A higher value results in lower volatility and slippage for traders.
                virtual_mult_range_DAO: 100,//A value of 100 means that for every 1 SUPRA the project aims to raise, the contract will create 100 SUPRA of virtual liquidity. A higher value results in lower volatility and slippage for traders.
                virtual_mult_range_BIG_DAO: 70,//A value of 70 means that for every 1 SUPRA the project aims to raise, the contract will create 70 SUPRA of virtual liquidity. A higher value results in lower volatility and slippage for traders.
                tokens_per_sup: 137, //ratio tokens per sup
                raising_percentage_meme: 100, //1% to dev when boundingcurve raised
                raising_percentage_DAO: 300, //3% to dev when boundingcurve raised
                raising_percentage_BIG_DAO: 700, //7% to dev when boundingcurve raised
                token_decimals: 8,
                min_trade_supra_amount: 100_000_000,
                deadline: 10800,
                unstake_period_seconds_default: 2592000, //30 days
                unstake_period_seconds_min: MIN_UNSTAKE_PERIOD,
                unstake_period_seconds_max: MAX_UNSTAKE_PERIOD,
                migrator_reward_bps: 37, //0.37% migrator reward
                migration_gas_amount: 100_000_000,
                migration_slippage_bps: 300, //3%
                supply_deviation_tolerance_bps: 2000, // 20%
            }
        );

        move_to(
            pump_admin,
            TimelockState {
                pending_proposal: option::none<PendingProposal>(),
                delay: 259200, // 72 hours by default
                admin: address_of(pump_admin),
            }
        );

        let pool_record = PoolRecord {
            records: simple_map::create(),
            real_supra_reserves: simple_map::create()
        };
        move_to(&resource_account, pool_record);
        coin::register<SupraCoin>(&resource_account);
    }

    fun deploy_internal(
        caller: &signer,
        raising: u64,
        description: String,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        telegram: String,
        twitter: String,
        github: String,
        stream: String,
        unstake_period_seconds: u64
    ): address acquires PumpConfig, Handle, PoolRecord {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let fee_amount = config.deploy_fee;
        if (fee_amount > 0) {
            let deploy_fee_coin = coin::withdraw<SupraCoin>(caller, fee_amount);
            coin::deposit(config.platform_fee_address, deploy_fee_coin);
        };
        let (virtual_supra_reserves, virtual_token_reserves) = calculate_virtual_pools_internal(config, raising);
        let percentage_reward_bps = get_percentage_bps_reward_internal(config, raising);
        assert!(
            (raising >= config.raise_limit_min) && (raising <= config.raise_limit_max),
            error::invalid_argument(ERROR_INVALID_RAISE)
        );
        assert!(string::length(&description) <= 1370, error::invalid_argument(ERROR_INVALID_LENGTH));
        assert!(string::length(&name) <= 73, error::invalid_argument(ERROR_INVALID_LENGTH));
        assert!(string::length(&symbol) <= 73, error::invalid_argument(ERROR_INVALID_LENGTH));
        assert!(string::length(&uri) <= 274, error::invalid_argument(ERROR_INVALID_LENGTH));
        assert!(string::length(&website) <= 274, error::invalid_argument(ERROR_INVALID_LENGTH));
        assert!(string::length(&telegram) <= 274, error::invalid_argument(ERROR_INVALID_LENGTH));
        assert!(string::length(&twitter) <= 274, error::invalid_argument(ERROR_INVALID_LENGTH));
        assert!(string::length(&github) <= 274, error::invalid_argument(ERROR_INVALID_LENGTH));
        assert!(string::length(&stream) <= 274, error::invalid_argument(ERROR_INVALID_LENGTH));

        let min_limit = config.raise_limit_min;
        let max_limit = config.raise_limit_max;
        let lower_threshold = (((max_limit - min_limit) * 1) / 3) + min_limit;
        let upper_threshold = (((max_limit - min_limit) * 2) / 3) + min_limit;

        let project_type_string = if (raising <= lower_threshold) {
            string::utf8(b"Meme")
        } else if (raising <= upper_threshold) {
            string::utf8(b"DAO")
        } else {
            string::utf8(b"BIG_DAO")
        };

        let final_unstake_period = if (unstake_period_seconds > 0) {
            assert!(
                unstake_period_seconds >= config.unstake_period_seconds_min &&
                unstake_period_seconds <= config.unstake_period_seconds_max,
                error::invalid_argument(ERROR_INVALID_UNSTAKE_PERIOD)
            );
            unstake_period_seconds
        } else {
            config.unstake_period_seconds_default
        };

        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        let resource_signer = account::create_signer_with_capability(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), error::not_found(ERROR_PUMP_NOT_EXIST));
        let sender = address_of(caller);

        let (token_address, stake_transfer_ref, reward_transfer_ref) = asset_manager::create_fa(
            name,
            symbol,
            config.token_decimals,
            uri,
            website
        );

        register_if_needed(caller, token_address);
        
        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let pool = Pool {
            initial_virtual_token_supply: virtual_token_reserves,
            initial_virtual_supra_reserves: virtual_supra_reserves,
            virtual_token_reserves: virtual_token_reserves,
            virtual_supra_reserves: virtual_supra_reserves,
            target_supra_dex_threshold: raising,
            raising_percent: percentage_reward_bps,
            is_completed: false,
            is_migrated_to_dex: false,
            dev: sender,
            migration_snapshot_v_token_reserves: 0,
            migration_snapshot_v_supra_reserves: 0,
        };

        let token_pair_record = TokenPairRecord {
            name: name,
            symbol: symbol,
            pool
        };

        simple_map::add(&mut pool_record.records, token_address, token_pair_record);
        simple_map::add(
            &mut pool_record.real_supra_reserves, token_address, coin::zero<SupraCoin>()
        );

        hodl_fa::register_hodl_pool(
            &resource_signer,
            token_address,
            token_address,
            stake_transfer_ref,    
            reward_transfer_ref,     
            final_unstake_period,
            option::none()
        );

        event::emit_event(
            &mut borrow_global_mut<Handle>(MODULE_ADMIN).created_events,

            PumpEvent {
                project_type: project_type_string,
                pool: type_name<Pool>(),
                dev: sender,
                description,
                name,
                symbol,
                token_address,
                uri,
                website,
                telegram,
                twitter,
                github,
                stream,
                platform_fee: config.platform_fee,
                initial_virtual_token_reserves: virtual_token_reserves,
                initial_virtual_supra_reserves: virtual_supra_reserves,
                token_decimals: config.token_decimals,
                unstake_period_seconds: final_unstake_period
            }
        );
        token_address
    }

        fun get_raise_limits(config: &PumpConfig): (u64, u64, u64, u64) {
        let min_limit = config.raise_limit_min;
        let max_limit = config.raise_limit_max;
        let lower_threshold = (((max_limit - min_limit) * 1) / 3) + min_limit;
        let upper_threshold = (((max_limit - min_limit) * 2) / 3) + min_limit;
        (min_limit, lower_threshold, upper_threshold, max_limit)
    }

    fun calculate_virtual_pools_internal(config: &PumpConfig, raising: u64): (u128, u128) {
        let (min_limit, lower_threshold, upper_threshold, max_limit) = get_raise_limits(config);
        assert!(raising >= min_limit && raising <= max_limit, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));

        let virtual_supra_reserves_u128: u128;
        if (raising <= lower_threshold) {
            virtual_supra_reserves_u128 = (raising as u128) * (config.virtual_mult_range_meme as u128);
        } else if (raising <= upper_threshold) {
            virtual_supra_reserves_u128 = (raising as u128) * (config.virtual_mult_range_DAO as u128);
        } else {
            virtual_supra_reserves_u128 = (raising as u128) * (config.virtual_mult_range_BIG_DAO as u128);
        };

        assert!(config.token_decimals <= MAX_TOKEN_DECIMALS, error::invalid_argument(ERROR_TOKEN_DECIMAL));
        let factor_u128 = math128::pow((10 as u128), (config.token_decimals as u128));
        
        let tokens_per_sup_u128 = (config.tokens_per_sup as u128);
        let supra_decimals_u128 = (DECIMALS as u128);

        if (tokens_per_sup_u128 > 0) {
            assert!(factor_u128 <= U128_MAX / tokens_per_sup_u128, error::invalid_argument(ERROR_OVERFLOW));
        };

        let intermediate_result = math128::mul_div(
            virtual_supra_reserves_u128,
            tokens_per_sup_u128,
            supra_decimals_u128
        );
        let virtual_token_reserves_u256 = (intermediate_result as u256) * (factor_u128 as u256);

        assert!(virtual_token_reserves_u256 <= (U128_MAX as u256), error::invalid_argument(ERROR_OVERFLOW));
        let virtual_token_reserves_u128 = (virtual_token_reserves_u256 as u128);
        (virtual_supra_reserves_u128, virtual_token_reserves_u128)
    }

    fun get_percentage_bps_reward_internal(config: &PumpConfig, raising: u64): u64 {
        let (min_limit, lower_threshold, upper_threshold, max_limit) = get_raise_limits(config);
        assert!(raising >= min_limit && raising <= max_limit, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));

        if (raising <= lower_threshold) {
            config.raising_percentage_meme
        } else if (raising <= upper_threshold) {
            config.raising_percentage_DAO
        } else {
            config.raising_percentage_BIG_DAO
        }
    }

    fun buy_tokens_for_exact_supra_internal(
        caller: &signer,
        token_address: address,
        supra_in_amount: u64,
        min_token_out: u64
    ) acquires PumpConfig, PoolRecord, Handle {
        assert!(supra_in_amount > 0, error::invalid_argument(ERROR_PUMP_AMOUNT_IS_NULL));
        let sender = address_of(caller);
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        register_if_needed(caller, token_address);

        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record = simple_map::borrow_mut<address, TokenPairRecord>(&mut pool_record.records, &token_address);
        assert!(!token_pair_record.pool.is_completed, error::invalid_state(ERROR_PUMP_COMPLETED));

        let dev_address = token_pair_record.pool.dev;

        let platform_fee = math64::mul_div(supra_in_amount, config.platform_fee, 10000);
        let creator_fee = math64::mul_div(supra_in_amount, config.creator_fee_bps, 10000); 
        let total_fees = platform_fee + creator_fee;

        assert!(supra_in_amount > total_fees, error::invalid_argument(ERROR_AMOUNT_TOO_LOW));
        let supra_to_pool_amount_u64 = supra_in_amount - total_fees;

        let tokens_to_receive_u128 = (
            calculate_buy_token(
                (token_pair_record.pool.virtual_token_reserves),
                (token_pair_record.pool.virtual_supra_reserves),
                (supra_to_pool_amount_u64 as u128)
            )
        );
        
        assert!(tokens_to_receive_u128 <= U64_MAX_AS_U128, error::invalid_argument(ERROR_OVERFLOW));
        let tokens_to_receive_u64 = (tokens_to_receive_u128 as u64);
        assert!(tokens_to_receive_u64 > 0, error::invalid_argument(ERROR_PUMP_AMOUNT_TO_LOW));
        assert!(tokens_to_receive_u64 >= min_token_out, error::out_of_range(ERROR_SLIPPAGE_TOO_HIGH));

        let total_supra_coin = coin::withdraw<SupraCoin>(caller, supra_in_amount);

        let platform_fee_coin = coin::extract(&mut total_supra_coin, platform_fee);
        let creator_fee_coin = coin::extract(&mut total_supra_coin, creator_fee);

        get_token_by_sup(&mut token_pair_record.pool, (supra_to_pool_amount_u64 as u128), tokens_to_receive_u128);
        if (coin::is_account_registered<SupraCoin>(dev_address)) {
            coin::deposit(dev_address, creator_fee_coin);
        } else {
            coin::merge(&mut platform_fee_coin, creator_fee_coin);
        };
        coin::deposit(config.platform_fee_address, platform_fee_coin);

        asset_manager::mint(token_address, sender, tokens_to_receive_u64);

        let real_supra_reserves = simple_map::borrow_mut<address, Coin<SupraCoin>>(&mut pool_record.real_supra_reserves, &token_address);
        coin::merge<SupraCoin>(real_supra_reserves, total_supra_coin);

        event::emit_event(
            &mut borrow_global_mut<Handle>(MODULE_ADMIN).trade_events,
            TradeEvent {
                supra_amount: supra_to_pool_amount_u64,
                is_buy: true,
                token_address: token_address,
                token_amount: tokens_to_receive_u64,
                user: sender,
                virtual_supra_reserves: token_pair_record.pool.virtual_supra_reserves,
                virtual_token_reserves: token_pair_record.pool.virtual_token_reserves,
                timestamp: timestamp::now_seconds(),
                platform_fee: platform_fee,
                creator_fee: creator_fee,
            }
        );

        let current_supra_balance = coin::value(real_supra_reserves);
        let required_balance_for_migration = token_pair_record.pool.target_supra_dex_threshold + config.migration_gas_amount;

        if (current_supra_balance >= required_balance_for_migration && !token_pair_record.pool.is_completed) {
            prepare_for_migration(token_pair_record);
        }
    }

    fun prepare_supra_for_migration(
        real_supra_reserves_mut: &mut Coin<SupraCoin>,
        target_threshold: u64,
        config: &PumpConfig,
    ): (u64, u64) {
        let excess_supra_collected = 0u64;
        let current_supra_in_pool = coin::value(real_supra_reserves_mut);

        if (current_supra_in_pool > target_threshold) {
            let excess_amount = current_supra_in_pool - target_threshold;
            let excess_coin = coin::extract(real_supra_reserves_mut, excess_amount);
            coin::deposit(config.benefitiary_address_for_excess, excess_coin);
            excess_supra_collected = excess_amount;
        };
        
        let supra_post_trimming = coin::value(real_supra_reserves_mut);
        let gas_deduction_amount = config.migration_gas_amount;
        assert!(supra_post_trimming > gas_deduction_amount, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));
        
        let gas_deduction_coin = coin::extract(real_supra_reserves_mut, gas_deduction_amount);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        coin::deposit(resource_addr, gas_deduction_coin);

        let supra_value_for_amm = coin::value(real_supra_reserves_mut);
        (supra_value_for_amm, excess_supra_collected)
    }

    fun calculate_migration_mints(
        pool: &Pool,
        config: &PumpConfig,
        supra_value_for_amm: u64
    ): (u64, MigrationRewards) {

        let ideal_token_supply = calculate_ideal_projected_supply_base(
            pool.initial_virtual_token_supply,
            pool.initial_virtual_supra_reserves,
            pool.target_supra_dex_threshold
        );
        
        let tokens_for_lp_u128 = math128::mul_div(
            (supra_value_for_amm as u128),
            pool.migration_snapshot_v_token_reserves,
            pool.migration_snapshot_v_supra_reserves
        );

        let dev_reward_u128 = math128::mul_div(ideal_token_supply, (pool.raising_percent as u128), 10000);
        let staking_reward_u128 = math128::mul_div(ideal_token_supply, 100, 10000); // 1%
        let migrator_reward_u128 = math128::mul_div(ideal_token_supply, (config.migrator_reward_bps as u128), 10000);

        assert!(tokens_for_lp_u128 <= U64_MAX_AS_U128, error::invalid_argument(ERROR_OVERFLOW));
        assert!(dev_reward_u128 <= U64_MAX_AS_U128, error::invalid_argument(ERROR_OVERFLOW));
        assert!(staking_reward_u128 <= U64_MAX_AS_U128, error::invalid_argument(ERROR_OVERFLOW));
        assert!(migrator_reward_u128 <= U64_MAX_AS_U128, error::invalid_argument(ERROR_OVERFLOW));

        let tokens_for_lp = (tokens_for_lp_u128 as u64);
        assert!(tokens_for_lp > 0, error::invalid_state(ERROR_MIGRATION_STATE_INCONSISTENCY));

        let rewards = MigrationRewards {
            dev_reward: (dev_reward_u128 as u64),
            staking_reward: (staking_reward_u128 as u64),
            migrator_reward: (migrator_reward_u128 as u64),
        };

        (tokens_for_lp, rewards)
    }

    fun mint_and_distribute_rewards(
        token_address: address,
        rewards: &MigrationRewards,
        resource_signer: &signer,
        pool_key_staking: &hodl_fa::PoolIdentifier,
        dev_address: address,
        migrator_address: address,
    ) {
        let resource_addr = address_of(resource_signer);

        if (rewards.dev_reward > 0) {
            asset_manager::mint(token_address, resource_addr, rewards.dev_reward);
            
            let token_metadata_obj = object::address_to_object<Metadata>(token_address);
            if (!primary_fungible_store::primary_store_exists(resource_addr, token_metadata_obj)) {
                primary_fungible_store::create_primary_store(resource_addr, token_metadata_obj);
            };

            let primary_store = primary_fungible_store::primary_store(resource_addr, token_metadata_obj);
            let dev_reward_asset = fungible_asset::withdraw(resource_signer, primary_store, rewards.dev_reward);


            hodl_fa::deposit_and_stake_for_beneficiary(
                resource_signer, 
                *pool_key_staking,
                dev_address, 
                dev_reward_asset
            );
        };

        asset_manager::mint(token_address, resource_addr, rewards.staking_reward);
        hodl_fa::finalize_hodl_pool_rewards(resource_signer, *pool_key_staking, rewards.staking_reward);
        
        asset_manager::mint(token_address, migrator_address, rewards.migrator_reward);
        asset_manager::disable_minting(token_address);

    }

    fun orchestrate_migration_to_amm(
        caller: &signer,
        token_address: address,
        pool: &mut Pool,
        real_supra_reserves_mut: &mut Coin<SupraCoin>,
        slippage_bps: u64
    ) acquires PumpConfig, Handle {
        let migrator_address = address_of(caller);
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        let resource_signer = account::create_signer_with_capability(&config.resource_cap);
        
        let (supra_value_for_amm, excess_collected) = prepare_supra_for_migration(
            real_supra_reserves_mut,
            pool.target_supra_dex_threshold,
            config
        );
        let supra_coin_for_amm = coin::extract_all<SupraCoin>(real_supra_reserves_mut);
        coin::deposit<SupraCoin>(resource_addr, supra_coin_for_amm);

        let (tokens_for_lp, rewards) = calculate_migration_mints(
            pool,
            config,
            supra_value_for_amm
        );
        
        let pool_key_staking = hodl_fa::new_pool_identifier(resource_addr, token_address, token_address);
        asset_manager::make_token_fungible(token_address);
        mint_and_distribute_rewards(
            token_address,
            &rewards,
            &resource_signer,
            &pool_key_staking,
            pool.dev,
            migrator_address
        );

        asset_manager::mint(token_address, resource_addr, tokens_for_lp);
        assert!(slippage_bps <= 10000, ERROR_SLIPPAGE_TOO_HIGH);
        let slippage_numerator = 10000 - slippage_bps;
        let amount_token_min = math64::mul_div(tokens_for_lp, slippage_numerator, 10000);
        let amount_supra_min = math64::mul_div(supra_value_for_amm, slippage_numerator, 10000);
        let tx_deadline = timestamp::now_seconds() + config.deadline;

        let (amount0, amount1, lp_amount, lp_token_metadata) = amm_router::add_liquidity_coin_aux_beta<SupraCoin>(
            &resource_signer,
            token_address,
            tokens_for_lp,
            amount_token_min,
            supra_value_for_amm,
            amount_supra_min,
            resource_addr,
            tx_deadline,
        );

        let lp_tokens = primary_fungible_store::withdraw(&resource_signer, lp_token_metadata, lp_amount);
        let supra_metadata_obj = coin_wrapper::get_wrapper<SupraCoin>();
        let bwsup = object::object_address(&supra_metadata_obj);
        LPStorage::deposit_lp(lp_token_metadata, lp_tokens, token_address, bwsup, amount0, amount1);
        
        pool.is_migrated_to_dex = true;

        event::emit_event(
            &mut borrow_global_mut<Handle>(MODULE_ADMIN).migration_events,
            MigrationToAmmEvent {
                token_address: token_address, 
                migrator: migrator_address, 
                supra_sent_to_lp: amount1,
                tokens_sent_to_lp: amount0,
                dev_reward_staked: rewards.dev_reward,
                staking_pool_reward: rewards.staking_reward,
                migrator_reward: rewards.migrator_reward,
                excess_supra_collected: excess_collected
            }
        );
    }

    public entry fun deploy(
        caller: &signer,
        raising: u64,
        description: String,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        telegram: String,
        twitter: String,
        github: String,
        stream: String,
        unstake_period_seconds: u64
    ) acquires PumpConfig, Handle, PoolRecord {
        deploy_internal(caller, raising, description, name, symbol, uri, website, telegram, twitter, github, stream, unstake_period_seconds);
    }

    public entry fun swap_supra_for_exact_tokens(
        caller: &signer,
        token_address: address,
        buy_token_amount: u64,
        max_supra_in: u64
    ) acquires PumpConfig, PoolRecord, Handle {
        assert!(buy_token_amount > 0, error::invalid_argument(ERROR_PUMP_AMOUNT_IS_NULL));
        register_if_needed(caller, token_address);
        let sender = address_of(caller);
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);

        let token_pair_record =
            simple_map::borrow_mut<address, TokenPairRecord>(
                &mut pool_record.records, &token_address
            );

        assert!(!token_pair_record.pool.is_completed, error::invalid_state(ERROR_PUMP_COMPLETED));
        assert!((buy_token_amount as u128) < token_pair_record.pool.virtual_token_reserves, error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY));

        let liquidity_cost_u128 = calculate_add_liquidity_cost(
            (token_pair_record.pool.virtual_supra_reserves),
            (token_pair_record.pool.virtual_token_reserves),
            (buy_token_amount as u128)
        );

        assert!(liquidity_cost_u128 >= (config.min_trade_supra_amount as u128), error::invalid_argument(ERROR_AMOUNT_TOO_LOW));

        let platform_fee_u128 = math128::mul_div(liquidity_cost_u128, (config.platform_fee as u128), 10000);
        let creator_fee_u128 = math128::mul_div(liquidity_cost_u128, (config.creator_fee_bps as u128), 10000);

        let total_cost_u128 = liquidity_cost_u128 + platform_fee_u128 + creator_fee_u128;
        assert!(total_cost_u128 <= U64_MAX_AS_U128, error::invalid_argument(ERROR_OVERFLOW));
        let total_cost_u64 = (total_cost_u128 as u64);
        assert!(total_cost_u64  <= max_supra_in, error::out_of_range(ERROR_SLIPPAGE_TOO_HIGH));

        let total_supra_coin = coin::withdraw<SupraCoin>(caller, total_cost_u64);

        let platform_fee_u64 = (platform_fee_u128 as u64);
        let creator_fee_u64 = (creator_fee_u128 as u64);

        let platform_fee_coin = coin::extract(&mut total_supra_coin, platform_fee_u64);
        let creator_fee_coin = coin::extract(&mut total_supra_coin, creator_fee_u64);
        
        let dev_address = token_pair_record.pool.dev;
        if (coin::is_account_registered<SupraCoin>(dev_address)) {
            coin::deposit(dev_address, creator_fee_coin);
        } else {
            coin::merge(&mut platform_fee_coin, creator_fee_coin);
        };
        coin::deposit(config.platform_fee_address, platform_fee_coin);

        get_token_by_sup(
            &mut token_pair_record.pool, 
            liquidity_cost_u128, 
            (buy_token_amount as u128)
        );

        asset_manager::mint(
            token_address,
            sender,
            buy_token_amount
        );
        
        let real_supra_reserves =
        simple_map::borrow_mut<address, Coin<SupraCoin>>(
            &mut pool_record.real_supra_reserves, &token_address
        );    
        coin::merge<SupraCoin>(real_supra_reserves, total_supra_coin); 

        event::emit_event(
            &mut borrow_global_mut<Handle>(MODULE_ADMIN).trade_events,
            TradeEvent {
                supra_amount: (liquidity_cost_u128 as u64),
                is_buy: true,
                token_address: token_address,
                token_amount: buy_token_amount,
                user: sender,
                virtual_supra_reserves: token_pair_record.pool.virtual_supra_reserves,
                virtual_token_reserves: token_pair_record.pool.virtual_token_reserves,
                timestamp: timestamp::now_seconds(),
                platform_fee: platform_fee_u64,
                creator_fee: creator_fee_u64,
            }
        );

        let current_supra_balance = coin::value(real_supra_reserves);
        if (current_supra_balance >= token_pair_record.pool.target_supra_dex_threshold && !token_pair_record.pool.is_completed) {
            prepare_for_migration(token_pair_record);
        }
    }

    public entry fun buy_tokens_for_exact_supra(
        caller: &signer,
        token_address: address,
        supra_in_amount: u64,
        min_token_out: u64
    ) acquires PumpConfig, PoolRecord, Handle {
        buy_tokens_for_exact_supra_internal(caller, token_address, supra_in_amount, min_token_out);
    }

    public entry fun deploy_and_buy_for_exact_supra(
        caller: &signer,
        raising: u64,
        description: String,
        name: String,
        symbol: String,
        uri: String,
        website: String,
        telegram: String,
        twitter: String,
        github: String,
        stream: String,
        unstake_period_seconds: u64,
        supra_in_amount: u64, 
        min_token_out: u64
    ) acquires PumpConfig, Handle, PoolRecord {
        let token_address = deploy_internal(
            caller, raising, description, name, symbol, uri,
            website, telegram, twitter, github, stream, unstake_period_seconds
        );

        if (supra_in_amount > 0) {
            buy_tokens_for_exact_supra_internal(
                caller, token_address, supra_in_amount, min_token_out
            );
        }
    }

    public entry fun swap_exact_tokens_for_supra(
        caller: &signer,
        token_address: address,
        sell_token_amount: u64,
        min_supra_out: u64
    ) acquires PumpConfig, PoolRecord, Handle {
        assert!(sell_token_amount > 0, error::invalid_argument(ERROR_PUMP_AMOUNT_IS_NULL));
        
        let sender = address_of(caller);
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), error::not_found(ERROR_PUMP_NOT_EXIST));
        
        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record = 
            simple_map::borrow_mut<address, TokenPairRecord>(
                &mut pool_record.records, &token_address
            );
        let pool = &mut token_pair_record.pool;
        
        assert!(!pool.is_completed, error::invalid_state(ERROR_PUMP_COMPLETED));
        
        let token_balance = asset_manager::get_balance(token_address, sender);

        assert!(sell_token_amount <= token_balance, error::resource_exhausted(ERROR_INSUFFICIENT_BALANCE));


        let real_supra_reserves = 
            simple_map::borrow_mut<address, Coin<SupraCoin>>(
                &mut pool_record.real_supra_reserves, &token_address
            );

        let supra_to_receive_u128  =
            (
                calculate_sell_token(
                    (pool.virtual_token_reserves),
                    (pool.virtual_supra_reserves),
                    (sell_token_amount as u128)
                )
            );
        assert!(supra_to_receive_u128 <= U64_MAX_AS_U128, error::invalid_argument(ERROR_OVERFLOW));
        let supra_to_receive_u64 = (supra_to_receive_u128 as u64);
        assert!(supra_to_receive_u64 >= min_supra_out, error::out_of_range(ERROR_SLIPPAGE_TOO_HIGH));
        assert!(
            supra_to_receive_u64 <= coin::value(real_supra_reserves),
            error::resource_exhausted(ERROR_INSUFFICIENT_LIQUIDITY)
        );
        
        assert!(supra_to_receive_u64 >= config.min_trade_supra_amount, error::invalid_argument(ERROR_AMOUNT_TOO_LOW));

        asset_manager::burn(
            token_address,
            sender,
            sell_token_amount
        );

        get_sup_by_token(pool,(sell_token_amount as u128), supra_to_receive_u128);

        let platform_fee = math64::mul_div(supra_to_receive_u64, config.platform_fee, 10000);
        let creator_fee = math64::mul_div(supra_to_receive_u64, config.creator_fee_bps, 10000);

        let supra_from_pool = coin::extract<SupraCoin>(
            real_supra_reserves, supra_to_receive_u64
        );
        let supra_amount_before_fees  = coin::value<SupraCoin>(&supra_from_pool);
        let platform_fee_coin = coin::extract<SupraCoin>(&mut supra_from_pool, platform_fee);
        let creator_fee_coin = coin::extract<SupraCoin>(&mut supra_from_pool, creator_fee);

        let dev_address = pool.dev;
        if (coin::is_account_registered<SupraCoin>(dev_address)) {
            coin::deposit(dev_address, creator_fee_coin);
        } else {
            coin::merge(&mut platform_fee_coin, creator_fee_coin);
        };

        coin::deposit(config.platform_fee_address, platform_fee_coin);
        coin::deposit(sender, supra_from_pool);

        event::emit_event(
            &mut borrow_global_mut<Handle>(MODULE_ADMIN).trade_events,
            TradeEvent {
                supra_amount: supra_amount_before_fees - platform_fee - creator_fee,
                is_buy: false,
                token_address: token_address,
                token_amount: sell_token_amount,
                user: sender,
                virtual_supra_reserves: pool.virtual_supra_reserves,
                virtual_token_reserves: pool.virtual_token_reserves,
                timestamp: timestamp::now_seconds(),
                platform_fee: platform_fee,
                creator_fee: creator_fee,
            }
        );
    }

    public entry fun stake(
        user: &signer,
        token_address: address,
        stake_amount: u64
    ) acquires PumpConfig, PoolRecord {
        assert!(stake_amount > 0, error::invalid_argument(ERROR_AMOUNT_TOO_LOW));
        let pool_key = get_validated_pool_key(token_address);
        let user_addr = address_of(user);
        let balance = asset_manager::get_balance(token_address, user_addr);
        assert!(balance >= stake_amount, error::resource_exhausted(ERROR_INSUFFICIENT_BALANCE));
        
        hodl_fa::stake(user, pool_key, stake_amount);
    }
    
    public entry fun unstake(
        user: &signer,
        token_address: address,
        unstake_amount: u64
    ) acquires PumpConfig, PoolRecord {
        assert!(unstake_amount > 0, error::invalid_argument(ERROR_AMOUNT_TOO_LOW));
        let pool_key = get_validated_pool_key(token_address);

        hodl_fa::unstake(user, pool_key, unstake_amount);

    }

    public entry fun harvest(
        user: &signer,
        token_address: address
    ) acquires PumpConfig, PoolRecord {
        let pool_key = get_validated_pool_key(token_address);
        let user_addr = address_of(user);

        let (_, harvested_rewards) = hodl_fa::harvest(user, pool_key);

        let reward_fa_metadata_obj = object::address_to_object<Metadata>(token_address);
        if (!primary_fungible_store::primary_store_exists(user_addr, reward_fa_metadata_obj)) {
            primary_fungible_store::create_primary_store(address_of(user), reward_fa_metadata_obj);
        };
        primary_fungible_store::deposit(user_addr, harvested_rewards);
    }

    public entry fun queue_update_all_configs(
        admin: &signer,
        new_creator_fee_bps: u64,
        new_platform_fee: u64,
        new_deploy_fee: u64,
        new_platform_fee_address: address,
        new_benefitiary_address_for_excess: address,
        new_raise_limit_min: u64,
        new_raise_limit_max: u64,
        new_virtual_mult_range_meme: u64,
        new_virtual_mult_range_DAO: u64,
        new_virtual_mult_range_BIG_DAO: u64,
        new_tokens_per_sup: u64,
        new_raising_percentage_meme: u64,
        new_raising_percentage_DAO: u64,
        new_raising_percentage_BIG_DAO: u64,
        new_staking_rate: u64,
        new_unstake_period_seconds_min: u64,
        new_unstake_period_seconds_max: u64,
        new_unstake_period_seconds_default: u64,
        new_migrator_reward_bps: u64,
        new_migration_gas_amount: u64,
        new_token_decimals: u8,
        new_min_trade_supra_amount: u64,
        new_deadline: u64,
        new_supply_deviation_tolerance_bps: u64,

    ) acquires TimelockState, Handle {

        let timelock_state_mut = borrow_global_mut<TimelockState>(MODULE_ADMIN);
        assert!(address_of(admin) == timelock_state_mut.admin, error::permission_denied(ERROR_NO_AUTH));

        assert!(new_raise_limit_min > 0 && new_raise_limit_min < new_raise_limit_max, error::invalid_argument(ERROR_INVALID_RAISE_LIMITS));
        assert!(new_unstake_period_seconds_min > 0 && new_unstake_period_seconds_min < new_unstake_period_seconds_max, error::invalid_argument(ERROR_INVALID_UNSTAKE_PERIOD));
        assert!(new_unstake_period_seconds_default >= new_unstake_period_seconds_min && new_unstake_period_seconds_default <= new_unstake_period_seconds_max, error::invalid_argument(ERROR_INVALID_UNSTAKE_PERIOD));

        assert!(new_platform_fee <= MAX_PLATFORM_FEE_BPS, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        assert!(new_creator_fee_bps <= MAX_CREATOR_FEE_BPS, error::invalid_argument(ERROR_FEE_TOO_HIGH));
        assert!(new_migrator_reward_bps <= MAX_MIGRATOR_REWARD_BPS, error::invalid_argument(ERROR_SLIPPAGE_TOO_HIGH));
        assert!(new_raising_percentage_meme <= MAX_RAISING_PERCENTAGE, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        assert!(new_raising_percentage_DAO <= MAX_RAISING_PERCENTAGE, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        assert!(new_raising_percentage_BIG_DAO <= MAX_RAISING_PERCENTAGE, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        
        assert!(new_tokens_per_sup > 0, error::invalid_argument(ERROR_VIRTUAL_PRICE_CANNOT_BE_ZERO));
        assert!(new_virtual_mult_range_meme >= MIN_VIRTUAL_MULTIPLIER && new_virtual_mult_range_meme <= MAX_VIRTUAL_MULTIPLIER, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        assert!(new_virtual_mult_range_DAO >= MIN_VIRTUAL_MULTIPLIER && new_virtual_mult_range_DAO <= MAX_VIRTUAL_MULTIPLIER, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        assert!(new_virtual_mult_range_BIG_DAO >= MIN_VIRTUAL_MULTIPLIER && new_virtual_mult_range_BIG_DAO <= MAX_VIRTUAL_MULTIPLIER, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));
        
        assert!(new_token_decimals >= MIN_TOKEN_DECIMALS && new_token_decimals <= MAX_TOKEN_DECIMALS, error::invalid_argument(ERROR_TOKEN_DECIMAL));
        assert!(new_supply_deviation_tolerance_bps <= MAX_SUPPLY_DEVIATION_TOLERANCE_BPS, error::invalid_argument(ERROR_OUT_OF_THE_RANGE));

        let new_proposal = PendingProposal {
            proposer: address_of(admin),
            eta: timestamp::now_seconds() + timelock_state_mut.delay,
            new_creator_fee_bps,
            new_platform_fee,
            new_deploy_fee,
            new_platform_fee_address,
            new_benefitiary_address_for_excess,
            new_raise_limit_min,
            new_raise_limit_max,
            new_staking_rate,
            new_virtual_mult_range_meme,
            new_virtual_mult_range_DAO,
            new_virtual_mult_range_BIG_DAO,
            new_tokens_per_sup,
            new_raising_percentage_meme,
            new_raising_percentage_DAO,
            new_raising_percentage_BIG_DAO,
            new_token_decimals,
            new_min_trade_supra_amount,
            new_deadline,
            new_unstake_period_seconds_default,
            new_unstake_period_seconds_min,
            new_unstake_period_seconds_max,
            new_migrator_reward_bps,
            new_migration_gas_amount,
            new_supply_deviation_tolerance_bps,
        };
        timelock_state_mut.pending_proposal = option::some(new_proposal);

        event::emit_event(
            &mut borrow_global_mut<Handle>(MODULE_ADMIN).proposal_queued_events,
            ProposalQueued {
                proposer: address_of(admin),
                eta: timelock_state_mut.delay + timestamp::now_seconds(),
                target_function: string::utf8(b"update_all_configs"),
            }
        );
    }

    public entry fun execute_queued_config(executor: &signer) acquires TimelockState, PumpConfig, Handle {
        let timelock_state = borrow_global_mut<TimelockState>(MODULE_ADMIN);
        assert!(option::is_some<PendingProposal>(&timelock_state.pending_proposal), error::not_found(ERROR_PUMP_NOT_EXIST));
        
        let proposal = option::extract<PendingProposal>(&mut timelock_state.pending_proposal);

        assert!(timestamp::now_seconds() >= proposal.eta, error::permission_denied(ERROR_PUMP_NOT_COMPLETED));
        
        let config = borrow_global_mut<PumpConfig>(MODULE_ADMIN);
        config.creator_fee_bps = proposal.new_creator_fee_bps;
        config.platform_fee = proposal.new_platform_fee;
        config.benefitiary_address_for_excess = proposal.new_benefitiary_address_for_excess;
        config.deploy_fee = proposal.new_deploy_fee;
        config.platform_fee_address = proposal.new_platform_fee_address;
        config.raise_limit_min = proposal.new_raise_limit_min;
        config.raise_limit_max = proposal.new_raise_limit_max;
        config.staking_rate = proposal.new_staking_rate;
        config.virtual_mult_range_meme = proposal.new_virtual_mult_range_meme;
        config.virtual_mult_range_DAO = proposal.new_virtual_mult_range_DAO;
        config.virtual_mult_range_BIG_DAO = proposal.new_virtual_mult_range_BIG_DAO;
        config.tokens_per_sup = proposal.new_tokens_per_sup;
        config.raising_percentage_meme = proposal.new_raising_percentage_meme;
        config.raising_percentage_DAO = proposal.new_raising_percentage_DAO;
        config.raising_percentage_BIG_DAO = proposal.new_raising_percentage_BIG_DAO;
        config.token_decimals = proposal.new_token_decimals;
        config.min_trade_supra_amount = proposal.new_min_trade_supra_amount;
        config.deadline = proposal.new_deadline;
        config.unstake_period_seconds_default = proposal.new_unstake_period_seconds_default;
        config.unstake_period_seconds_min = proposal.new_unstake_period_seconds_min;
        config.unstake_period_seconds_max = proposal.new_unstake_period_seconds_max;
        config.migrator_reward_bps = proposal.new_migrator_reward_bps;
        config.migration_gas_amount = proposal.new_migration_gas_amount;
        config.supply_deviation_tolerance_bps = proposal.new_supply_deviation_tolerance_bps;

        event::emit_event(
            &mut borrow_global_mut<Handle>(MODULE_ADMIN).proposal_executed_events,
            ProposalExecuted {
                executor: address_of(executor),
                eta: proposal.eta,
            }
        );
    }
        
    public entry fun cancel_queued_config(admin: &signer) acquires TimelockState, Handle {
        let timelock_state_mut = borrow_global_mut<TimelockState>(MODULE_ADMIN);
        assert!(address_of(admin) == timelock_state_mut.admin, error::permission_denied(ERROR_NO_AUTH));
        assert!(option::is_some<PendingProposal>(&timelock_state_mut.pending_proposal), error::not_found(ERROR_PUMP_NOT_EXIST));

        timelock_state_mut.pending_proposal = option::none<PendingProposal>();

        event::emit_event(
            &mut borrow_global_mut<Handle>(MODULE_ADMIN).proposal_canceled_events,
            ProposalCanceled {
                canceller: address_of(admin),
            }
        );
    }

    public entry fun execute_manual_migration(
        caller: &signer,
        token_address: address,
    ) acquires PumpConfig, PoolRecord, Handle {
        execute_manual_migration_internal(caller, token_address);
    }

    public fun execute_manual_migration_internal(
        caller: &signer,
        token_address: address,
    ) acquires PumpConfig, PoolRecord, Handle {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        
        let token_pair_record = simple_map::borrow_mut<address, TokenPairRecord>(&mut pool_record.records, &token_address);
        assert!(token_pair_record.pool.is_completed, error::invalid_state(ERROR_PUMP_NOT_COMPLETED));
        assert!(!token_pair_record.pool.is_migrated_to_dex, error::invalid_state(ERROR_PUMP_COMPLETED));

        let real_supra_reserves = simple_map::borrow_mut<address, Coin<SupraCoin>>(&mut pool_record.real_supra_reserves, &token_address);
        assert!(coin::value(real_supra_reserves) > 0, error::invalid_state(ERROR_MIGRATION_STATE_INCONSISTENCY));

        orchestrate_migration_to_amm(
            caller, 
            token_address, 
            &mut token_pair_record.pool,
            real_supra_reserves, 
            config.migration_slippage_bps
        );
    }

    #[view]
    public fun buy_token_amount(
        token_address: address, buy_token_amount: u64
    ): u128 acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);

        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), error::not_found(ERROR_PUMP_NOT_EXIST));

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_address
            );
        let pool = token_pair_record.pool;

        let token_amount = math128::min((buy_token_amount as u128), pool.virtual_token_reserves);

        let liquidity_cost =
            calculate_add_liquidity_cost(
                (pool.virtual_supra_reserves),
                (pool.virtual_token_reserves),
                (token_amount)
            );

        (liquidity_cost)
    }

    #[view]
    public fun get_current_pool_supra_balance(
        token_address: address
    ): u64 acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);

        let pool_record = borrow_global<PoolRecord>(resource_addr);
        if (simple_map::contains_key(&pool_record.real_supra_reserves, &token_address)) {
            let balance_ref = simple_map::borrow(&pool_record.real_supra_reserves, &token_address);
            coin::value(balance_ref)
        } else {
            0
        }
    }

    #[view]
    public fun buy_supra_amount(
        token_address: address, buy_supra_amount: u64
    ): u128 acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), error::not_found(ERROR_PUMP_NOT_EXIST));

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_address
            );
        let pool = token_pair_record.pool;

        (
            calculate_buy_token(
                (pool.virtual_token_reserves),
                (pool.virtual_supra_reserves),
                (buy_supra_amount as u128)
            )
        )
    }

    #[view]
    public fun sell_token(
        token_address: address, sell_token_amount: u64
    ): u128 acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);

        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), error::not_found(ERROR_PUMP_NOT_EXIST));

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_address
            );
        let pool = token_pair_record.pool;
        let liquidity_remove =
            calculate_sell_token(
                (pool.virtual_token_reserves),
                (pool.virtual_supra_reserves),
                (sell_token_amount as u128)
            );

        (liquidity_remove)
    }

    #[view]
    public fun get_current_price(
        token_address: address,
    ): u128 acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), error::not_found(ERROR_PUMP_NOT_EXIST));

        let pool_record = borrow_global_mut<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &mut pool_record.records, &token_address
            );
        let pool = token_pair_record.pool;
        assert!(!pool.is_completed, error::invalid_state(ERROR_PUMP_COMPLETED));

        let supra_reserves = (pool.virtual_supra_reserves);
        let token_reserves = (pool.virtual_token_reserves);

        let ret_price = math128::mul_div(supra_reserves, (DECIMALS as u128), token_reserves);

        (ret_price)
    }

    #[view]
    public fun get_pool_state(
        token_address: address
    ): PoolStateView acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), error::not_found(ERROR_PUMP_NOT_EXIST));

        let pool_record = borrow_global<PoolRecord>(resource_addr);
        
        assert!(
            simple_map::contains_key(&pool_record.records, &token_address),
            error::not_found(ERROR_PUMP_NOT_EXIST)
        );
        let token_pair_record = simple_map::borrow<address, TokenPairRecord>(
            &pool_record.records, &token_address
        );

        let pool = &token_pair_record.pool;

        PoolStateView {
            virtual_token_reserves: pool.virtual_token_reserves,
            virtual_supra_reserves: pool.virtual_supra_reserves,
            is_completed: pool.is_completed,
            is_migrated_to_dex: pool.is_migrated_to_dex,
            target_supra_dex_threshold: pool.target_supra_dex_threshold,
            dev_address: pool.dev,
        }
    }

    #[view]
    public fun buy_price_with_fee(
        token_address: address, buy_meme_amount: u64
    ): u128 acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let fee = config.platform_fee;
        let supra_amount = buy_supra_amount(
            token_address, buy_meme_amount
        );
        let platform_fee = math128::mul_div(supra_amount, (fee as u128), 10000);
        supra_amount + platform_fee
    }

    #[view]
    public fun sell_price_with_fee(
        token_address: address, sell_meme_amount: u64
    ): u128 acquires PumpConfig, PoolRecord {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let fee = config.platform_fee;
        let supra_amount = sell_token(token_address, sell_meme_amount);
        let platform_fee = math128::mul_div(supra_amount, (fee as u128), 10000);

        if (supra_amount > platform_fee) {
            supra_amount - platform_fee
        } else {
            0
        }
    }

    #[view]
    public fun get_price_impact(
        token_address: address,
        amount: u64,
        is_buy: bool
    ): u64 acquires PumpConfig, PoolRecord {
        if (amount == 0) {
            return 0
        };

        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        assert!(exists<PoolRecord>(resource_addr), error::not_found(ERROR_PUMP_NOT_EXIST));

        let pool_record = borrow_global<PoolRecord>(resource_addr);
        let token_pair_record =
            simple_map::borrow<address, TokenPairRecord>(
                &pool_record.records, &token_address
            );
        
        let pool = &token_pair_record.pool;

        let supra_reserves_u128 = pool.virtual_supra_reserves;
        let token_reserves_u128 = pool.virtual_token_reserves;
        let amount_u128 = (amount as u128);

        if (token_reserves_u128 == 0 || supra_reserves_u128 == 0) {
            return 0
        };

        let price_precision = (DECIMALS as u128); 
        
        let initial_price_u128 = math128::mul_div(supra_reserves_u128, price_precision, token_reserves_u128);
        
        let final_price_u128 = if (is_buy) {
            let supra_in = calculate_add_liquidity_cost(
                supra_reserves_u128, 
                token_reserves_u128, 
                amount_u128
            );

            let new_supra_u128 = supra_reserves_u128 + supra_in;
            
            if (token_reserves_u128 <= amount_u128) { return 10000 };
            let new_token_u128 = token_reserves_u128 - amount_u128;
            
            math128::mul_div(new_supra_u128, price_precision, new_token_u128)
        } else { 
            let supra_out = calculate_sell_token(
                token_reserves_u128, 
                supra_reserves_u128, 
                amount_u128
            );

            if (supra_reserves_u128 <= supra_out) { return 10000 };
            let new_supra_u128 = supra_reserves_u128 - supra_out;
            let new_token_u128 = token_reserves_u128 + amount_u128;

            math128::mul_div(new_supra_u128, price_precision, new_token_u128)
        };

        if (initial_price_u128 == 0) {
            return if (final_price_u128 > 0) { 10000 } else { 0 }
        };

        let price_diff_u128 = if (final_price_u128 > initial_price_u128) {
            final_price_u128 - initial_price_u128
        } else {
            initial_price_u128 - final_price_u128
        };
        
        let impact_bps_u128 = math128::mul_div(price_diff_u128, 10000, initial_price_u128);
        
        if (impact_bps_u128 > (10000 as u128)) {
            10000
        } else {
            (impact_bps_u128 as u64)
        }
    }

    #[view]
    public fun get_bonding_curve_progress_data(
        token_address: address
    ): (u64, u64, bool) acquires PumpConfig, PoolRecord {       
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        
        assert!(exists<PoolRecord>(resource_addr), error::not_found(ERROR_PUMP_NOT_EXIST));
        let target_amount: u64;
        let is_completed: bool;
        
        let pool_record_ref = borrow_global<PoolRecord>(resource_addr);
        assert!(
            simple_map::contains_key(&pool_record_ref.records, &token_address),
            error::not_found(ERROR_PUMP_NOT_EXIST)
        );
        let token_pair_record = simple_map::borrow(&pool_record_ref.records, &token_address);
        target_amount = token_pair_record.pool.target_supra_dex_threshold;
        is_completed = token_pair_record.pool.is_completed;
        let current_amount = get_current_pool_supra_balance(token_address);
        (current_amount, target_amount, is_completed)
    }



    #[view]
    public fun calculate_virtual_pools(raising: u64): (u128, u128) acquires PumpConfig {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        calculate_virtual_pools_internal(config, raising)
    }

    #[view]
    public fun get_percentage_bps_reward(raising: u64): u64 acquires PumpConfig {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        get_percentage_bps_reward_internal(config, raising)
    }

    #[view]
    public fun get_resource_address(): address acquires PumpConfig {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        account::get_signer_capability_address(&config.resource_cap)
    }

    #[view]
    public fun get_platform_fees(): (u64, u64, address) acquires PumpConfig {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        (
            config.platform_fee,
            config.deploy_fee,
            config.platform_fee_address
        )
    }

    #[view]
    public fun get_launch_parameters(): LaunchParameters acquires PumpConfig {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        
        LaunchParameters {
            raise_limit_min: config.raise_limit_min,
            raise_limit_max: config.raise_limit_max,            
            virtual_mult_range_meme: config.virtual_mult_range_meme,
            virtual_mult_range_DAO: config.virtual_mult_range_DAO,
            virtual_mult_range_BIG_DAO: config.virtual_mult_range_BIG_DAO,
            tokens_per_sup: config.tokens_per_sup,
            raising_percentage_meme_bps: config.raising_percentage_meme,
            raising_percentage_DAO_bps: config.raising_percentage_DAO,
            raising_percentage_BIG_DAO_bps: config.raising_percentage_BIG_DAO,
            unstake_period_seconds_default: config.unstake_period_seconds_default,
            unstake_period_seconds_min: config.unstake_period_seconds_min,
            unstake_period_seconds_max: config.unstake_period_seconds_max,
            default_token_decimals: config.token_decimals,
            staking_rate: config.staking_rate,
        }
    }

    #[view]
    public fun get_protocol_fees(): ProtocolFees acquires PumpConfig {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);

        ProtocolFees {
            swap_platform_fee_bps: config.platform_fee,
            swap_creator_fee_bps: config.creator_fee_bps,
            deploy_fee: config.deploy_fee,
            migrator_reward_bps: config.migrator_reward_bps,
            migration_gas_fee: config.migration_gas_amount,       
            platform_fee_address: config.platform_fee_address,
            benefitiary_address_for_excess: config.benefitiary_address_for_excess,
            min_trade_supra_amount: config.min_trade_supra_amount,
            migration_slippage_bps: config.migration_slippage_bps,
        }
    }

    
    #[view]
    public fun get_user_stake_info(
        token_address: address,
        user_addr: address
    ): (u64, u64) acquires PumpConfig {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let creator_addr = account::get_signer_capability_address(&config.resource_cap);
        
        let total_staked = hodl_fa::get_user_stake_or_zero(
            creator_addr,
            token_address, 
            token_address,
            user_addr
        );

        let unlocked_amount = hodl_fa::get_unlocked_stake_amount(
            creator_addr,
            token_address,
            token_address,
            user_addr
        );

        (unlocked_amount, total_staked)
    }

    #[view]
    public fun get_hodl_pool_stats(
        token_address: address
    ) : (u64, u128) acquires PumpConfig {
        
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        let resource_addr = account::get_signer_capability_address(&config.resource_cap);
        
        assert!(exists<PoolRecord>(resource_addr), error::not_found(ERROR_PUMP_NOT_EXIST));

        let total_staked = hodl_fa::get_pool_total_stake(
            resource_addr,
            token_address,              
            token_address
        );

        let total_supply = asset_manager::get_total_supply(token_address);
        
        (total_staked, total_supply)
    }

    #[view]
    public fun get_raise_limits_config(): (u64, u64) acquires PumpConfig {
        let config = borrow_global<PumpConfig>(MODULE_ADMIN);
        (
            config.raise_limit_min,
            config.raise_limit_max
        )
    }

    #[view]
    public fun calculate_ideal_projected_supply_base(
        initial_v_token: u128,
        initial_v_supra: u128,
        fundraising_goal_supra: u64
    ): u128 {
        let goal_supra_u128 = (fundraising_goal_supra as u128);

        assert!(initial_v_supra > 0, error::invalid_argument(ERROR_VIRTUAL_PRICE_CANNOT_BE_ZERO));

        let k_invariant_u256 = (initial_v_token as u256) * (initial_v_supra as u256);
        let final_v_supra_ideal = initial_v_supra + goal_supra_u128;
        assert!(final_v_supra_ideal > 0, error::invalid_state(ERROR_VIRTUAL_PRICE_CANNOT_BE_ZERO));
        
        let final_v_token_ideal_u256 = k_invariant_u256 / (final_v_supra_ideal as u256);

        let ideal_circulating_supply_u256 = (initial_v_token as u256) - final_v_token_ideal_u256;
        
        let ideal_tokens_for_amm_u256 = 
            ((goal_supra_u128 as u256) * final_v_token_ideal_u256) / (final_v_supra_ideal as u256);
        
        let projected_supply_base_for_rewards_u256 = ideal_circulating_supply_u256 + ideal_tokens_for_amm_u256;
        assert!(projected_supply_base_for_rewards_u256 <= (U128_MAX as u256), error::invalid_argument(ERROR_OVERFLOW));

        (projected_supply_base_for_rewards_u256 as u128)
    }
}