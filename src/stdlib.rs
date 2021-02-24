use crate::*;

macro_rules! pop {
    ($e:ident) => {
        match $e.pile.pop() {
            Some(e) => e,
            None => return Err("stack underflow"),
        }
    }
}

macro_rules! pop_as {
    ($e:ident, $($t:ident),+) => {
        match pop!($e) {
            $(ZfToken::$t(v) => v,)+
            _ => return Err("bad type"),
        }
    }
}

/// cond? quote --
#[allow(non_snake_case)]
pub fn IF(env: &mut ZfEnv) -> Result<(), &str> {
    let func = pop_as!(env, List);
    if Into::<bool>::into(pop!(env)) {
        ZfProc::User(func).exec(env)?;
    }
    Ok(())
}

/// name func --
#[allow(non_snake_case)]
pub fn PROC(env: &mut ZfEnv) -> Result<(), &str> {
    let quote = pop_as!(env, List);
    let name  = pop_as!(env, String);
    env.dict.insert(name, ZfProc::User(quote));
    Ok(())
}

/// -- d
#[allow(non_snake_case)]
pub fn DEPTH(env: &mut ZfEnv) -> Result<(), &str> {
    env.pile.push(ZfToken::Number(env.pile.len() as f64));
    Ok(())
}

/// a b c i=2 -- a b c b
#[allow(non_snake_case)]
pub fn PICK(env: &mut ZfEnv) -> Result<(), &str> {
    let i = pop_as!(env, Number) as usize;
    let v = env.pile[env.pile.len()-1-i].clone();
    env.pile.push(v);
    Ok(())
}

/// a b c i=1 -- a c b
#[allow(non_snake_case)]
pub fn ROLL(env: &mut ZfEnv) -> Result<(), &str> {
    let mut i = pop_as!(env, Number) as usize;

    let mut stuff = Vec::new();
    while i > 0 {
        stuff.push(pop!(env));
        i -= 1;
    }
    let needle = pop!(env);
    for thing in stuff.iter().rev() {
        env.pile.push(thing.clone());
    }
    env.pile.push(needle);

    Ok(())
}

/// a --
#[allow(non_snake_case)]
pub fn DROP(env: &mut ZfEnv) -> Result<(), &str> {
    let _ = pop!(env);
    Ok(())
}

/// a -- c
#[allow(non_snake_case)]
pub fn NOT(env: &mut ZfEnv) -> Result<(), &str> {
    let c = !Into::<bool>::into(pop!(env));
    env.pile.push(ZfToken::Number(if c {1f64} else {0f64}));
    Ok(())
}

/// a b -- c
#[allow(non_snake_case)]
pub fn CMP(env: &mut ZfEnv) -> Result<(), &str> {
    let (b, a) = (pop_as!(env, Number), pop_as!(env, Number));
    if a == b {
        env.pile.push(ZfToken::Number( 0f64));
    } else if a > b {
        env.pile.push(ZfToken::Number( 1f64));
    } else if a < b {
        env.pile.push(ZfToken::Number(-1f64));
    }
    Ok(())
}

/// a b -- c
#[allow(non_snake_case)]
pub fn PLUS(env: &mut ZfEnv) -> Result<(), &str> {
    let (b, a) = (pop_as!(env, Number), pop_as!(env, Number));
    env.pile.push(ZfToken::Number(a + b));
    Ok(())
}

/// a b -- c
#[allow(non_snake_case)]
pub fn SUB(env: &mut ZfEnv) -> Result<(), &str> {
    let (b, a) = (pop_as!(env, Number), pop_as!(env, Number));
    env.pile.push(ZfToken::Number(a - b));
    Ok(())
}

/// a b -- c
#[allow(non_snake_case)]
pub fn MUL(env: &mut ZfEnv) -> Result<(), &str> {
    let (b, a) = (pop_as!(env, Number), pop_as!(env, Number));
    env.pile.push(ZfToken::Number(a * b));
    Ok(())
}

/// a b -- c
#[allow(non_snake_case)]
pub fn DMOD(env: &mut ZfEnv) -> Result<(), &str> {
    let (b, a) = (pop_as!(env, Number), pop_as!(env, Number));
    env.pile.push(ZfToken::Number(a % b));
    env.pile.push(ZfToken::Number(a / b));
    Ok(())
}

/// a b -- c
#[allow(non_snake_case)]
pub fn bAND(env: &mut ZfEnv) -> Result<(), &str> {
    let b = pop_as!(env, Number) as usize;
    let a = pop_as!(env, Number) as usize;
    env.pile.push(ZfToken::Number((a & b) as f64));
    Ok(())
}

/// a b -- c
#[allow(non_snake_case)]
pub fn bOR(env: &mut ZfEnv) -> Result<(), &str> {
    let b = pop_as!(env, Number) as usize;
    let a = pop_as!(env, Number) as usize;
    env.pile.push(ZfToken::Number((a | b) as f64));
    Ok(())
}

/// a b -- c
#[allow(non_snake_case)]
pub fn bXOR(env: &mut ZfEnv) -> Result<(), &str> {
    let b = pop_as!(env, Number) as usize;
    let a = pop_as!(env, Number) as usize;
    env.pile.push(ZfToken::Number((a ^ b) as f64));
    Ok(())
}

/// a -- c
#[allow(non_snake_case)]
pub fn bNOT(env: &mut ZfEnv) -> Result<(), &str> {
    let a = pop_as!(env, Number) as usize;
    env.pile.push(ZfToken::Number((!a) as f64));
    Ok(())
}

/// a b -- c
#[allow(non_snake_case)]
pub fn SHL(env: &mut ZfEnv) -> Result<(), &str> {
    let b = pop_as!(env, Number) as usize;
    let a = pop_as!(env, Number) as usize;
    env.pile.push(ZfToken::Number((a << b) as f64));
    Ok(())
}

/// a b -- c
#[allow(non_snake_case)]
pub fn SHR(env: &mut ZfEnv) -> Result<(), &str> {
    let b = pop_as!(env, Number) as usize;
    let a = pop_as!(env, Number) as usize;
    env.pile.push(ZfToken::Number((a >> b) as f64));
    Ok(())
}

/// quote --
#[allow(non_snake_case)]
pub fn WHILE(env: &mut ZfEnv) -> Result<(), &str> {
    let quote = pop_as!(env, List);

    loop {
        let val = match env.pile.pop() {
            Some(v) => v,
            None => break,
        };

        if !Into::<bool>::into(val) {
            break;
        } else {
            run(&quote, env);
        }
    }

    Ok(())
}

/// var -- val
#[allow(non_snake_case)]
pub fn FETCH(env: &mut ZfEnv) -> Result<(), &str> {
    let var = pop_as!(env, String);
    if env.vars.contains_key(&var) {
        env.pile.push(env.vars[&var].clone());
    } else {
        return Err("unknown variable");
    }
    Ok(())
}

/// val var --
#[allow(non_snake_case)]
pub fn STORE(env: &mut ZfEnv) -> Result<(), &str> {
    let var = pop_as!(env, String);
    env.vars.insert(var, pop!(env));
    Ok(())
}

/// a --
#[allow(non_snake_case)]
pub fn io_TOS(env: &mut ZfEnv) -> Result<(), &str> {
    println!("{}", pop!(env));
    Ok(())
}

/// --
#[allow(non_snake_case)]
pub fn io_CR(_env: &mut ZfEnv) -> Result<(), &str> {
    println!("");
    Ok(())
}

/// --
#[allow(non_snake_case)]
pub fn DBG(env: &mut ZfEnv) -> Result<(), &str> {
    eprintln!("{:?}", env.pile);
    Ok(())
}
