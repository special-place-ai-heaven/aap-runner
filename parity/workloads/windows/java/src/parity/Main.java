package parity;

import java.util.stream.IntStream;

public final class Main {
    public static void main(String[] args) {
        int sum = IntStream.rangeClosed(1, 4).sum();
        String arch = System.getProperty("os.arch");
        System.out.println("hello from java sum=" + sum + " amd64=" + "amd64".equals(arch));
    }
}
