#[inline(never)]
fn secret(x: u32) -> u32 {
    let mut result = x;
    for i in 1..10 {
        if result % 2 == 0 {
            result = result.wrapping_mul(3).wrapping_add(i);
        } else {
            result = result.wrapping_mul(7).wrapping_sub(i);
        }
    }
    result
}

#[inline(never)]
fn check_password(input: &str) -> bool {
    let password = "sup3r_s3cr3t";
    if input.len() != password.len() {
        return false;
    }
    input.as_bytes()
        .iter()
        .zip(password.as_bytes())
        .all(|(a, b)| a == b)
}

fn main() {
    let val = secret(42);
    println!("result: {}", val);

    let test = "hello_world";
    if check_password(test) {
        println!("access granted");
    } else {
        println!("access denied");
    }
}
