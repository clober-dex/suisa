module suisa::stsui {
    use std::option;
    use std::ascii;

    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::url;

    struct STSUI has drop {}

    fun init(witness: STSUI, ctx: &mut TxContext) {
        let icon_url = url::new_unsafe(ascii::string(b"https://pbs.twimg.com/profile_images/1679045925556355075/lvEiK0XY_400x400.jpg"));
        let (treasury_cap, metadata) = coin::create_currency<STSUI>(witness, 9, b"stSUI", b"Staked Sui", b"Staked version of Sui", option::some(icon_url), ctx);
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx))
    }

    public fun mint_and_return_stsui(
        treasury_cap: &mut TreasuryCap<STSUI>, amount: u64, ctx: &mut TxContext
    ): Coin<STSUI> {
        coin::mint(treasury_cap, amount, ctx)
    }

    public entry fun mint(
        treasury_cap: &mut TreasuryCap<STSUI>, amount: u64, recipient: address, ctx: &mut TxContext
    ) {
        coin::mint_and_transfer(treasury_cap, amount, recipient, ctx)
    }

    public entry fun burn(treasury_cap: &mut TreasuryCap<STSUI>, coin: Coin<STSUI>) {
        coin::burn(treasury_cap, coin);
    }

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(STSUI {}, ctx)
    }
}