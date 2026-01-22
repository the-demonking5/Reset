<?php 

$str = rand();
$hashedCode = hash("sha512", $str);
echo " The generated hash code is: $hashedCode\n";

$matrixSize = 150;

// Generate the first matrix with random values between 1 and 10
$matrixA = array();
for ($i = 0; $i < $matrixSize; $i++) {
    for ($j = 0; $j < $matrixSize; $j++) {
        $matrixA[$i][$j] = rand(500, 1000);
    }
}

// Generate the second matrix with random values between 1 and 10
$matrixB = array();
for ($i = 0; $i < $matrixSize; $i++) {
    for ($j = 0; $j < $matrixSize; $j++) {
        $matrixB[$i][$j] = rand(500, 1000);
 }
}

// Initialize the result matrix with zeros
$resultMatrix = array();
for ($i = 0; $i < $matrixSize; $i++) {
    for ($j = 0; $j < $matrixSize; $j++) {
        $resultMatrix[$i][$j] = 0;
    }
}

// Perform matrix multiplication
for ($i = 0; $i < $matrixSize; $i++) {
    for ($j = 0; $j < $matrixSize; $j++) {
        for ($k = 0; $k < $matrixSize; $k++) {
            $resultMatrix[$i][$j] += $matrixA[$i][$k] * $matrixB[$k][$j];
        }
    }
}

// Print the result matrix
for ($i = 0; $i < $matrixSize; $i++) {
    for ($j = 0; $j < $matrixSize; $j++) {
        echo $resultMatrix[$i][$j] . " ";
    }
    echo "\n";
}

?>
